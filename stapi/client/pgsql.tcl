# $Id$

package require sttp_client
package require sttp_postgres

namespace eval ::sttp {
  proc make_sql_uri {table args} {
    while {[llength $args]} {
      set arg [lindex $args 0]
      set args [lrange $args 1 end]
      if {![regexp {^-(.*)} $arg _ opt]} {
	lappend cols [uri_esc $arg /?]
      } else {
	set val [lindex $args 0]
	set args [lrange $args 1 end]
        switch -- $opt {
	  cols {
	    foreach col $val {
	      lappend cols [uri_esc $col /?]
	    }
	  }
	  host { set host [uri_esc $val @/:] }
	  user { set user [uri_esc $val @/:] }
	  pass { set pass [uri_esc $val @/:] }
	  db { set db [uri_esc $val @/:] }
	  keys { lappend params [uri_esc _keys=[join $val :] &] }
	  key { lappend params [uri_esc _key=$val &] }
	  -* {
	    regexp {^-(.*)} $opt _ opt
	    lappend params [uri_esc $opt &=]=[uri_esc $val &]
	  }
	  * {
	    lappend params [uri_esc $opt &=]=[uri_esc $val &]
	  }
	}
      }
    }
    set uri sql://
    if [info exists user] {
      if [info exists pass] {
	append user : $pass
      }
      append uri $user @
    }
    if [info exists host] {
      append uri $host :
    }
    if [info exists db] {
      append uri $db
    }
    append uri / [uri_esc $table /?]
    if [info exists cols] {
      append uri / [join $cols /]
    }
    if [info exists params] {
      append uri ? [join $params &]
    }
    return $uri
  }

  proc uri_esc {string {extra ""}} {
    foreach c [split "%\"'<> $extra" ""] {
      scan $c "%c" i
      regsub -all "\[$c]" $string [format "%%%02X" $i] string
    }
    return $string
  }

  proc uri_unesc {string} {
    foreach c [split {\\$[} ""] {
      scan $c "%c" i
      regsub -all "\\$c" $string [format "%%%02X" $i] string
    }
    regsub -all {%([0-9A-Fa-f][0-9A-Fa-f])} $string {[format %c 0x\1]} string
    return [subst $string]
  }

  variable sqltable_seq 0
  proc connect_pgsql {table {address "-"} args} {
    variable sqltable_seq

    set params ""
    regexp {^([^?]*)[?](.*)} $table _ table params
    set path ""
    regexp {^/*([^/]*)/(.*)} $table _ table path
    set path [split $path "/"]
    set table [uri_unesc $table]

    foreach param [split $params "&"] {
      if [regexp {^([^=]*)=(.*)} $param _ name val] {
	set vars([uri_unesc $name]) [uri_unesc $val]
      } else {
	set vars([uri_unesc $name]) ""
      }
    }

    set raw_fields {}
    foreach {name type} [get_columns $table] {
      lappend raw_fields $name
      set field2type($name) $type
    }

    if [llength $path] {
      set raw_fields {}
      foreach field $path {
	set field [uri_unesc $field]
	if [regexp {^([^:]*):(.*)} $field _ field type] {
	  set field2type($field) $type
	}
        lappend raw_fields $field
      }
    }

    if {[info exists vars(_key)] || [info exists vars(_keys)]} {
      if {[lsearch $path _key] == -1} {
	set raw_fields [concat {_key} $raw_fields]
      }
    }

    if [info exists vars(_keys)] {
      regsub -all {[+: ]+} $vars(_keys) ":" vars(_keys)
      set keys [split $vars(_keys) ":"]
      if {[llength $keys] == 1} {
	set vars(_key) [lindex $keys 0]
      } elseif {[llength $keys] > 1} {
	set list {}
        foreach field $keys {
	  if [info exists vars($field)] {
	    lappend list $vars($field)
	  } else {
	    set type varchar
	    if {[info exists field2type($field)]} {
	      set type $field2type($field)
	    }
	    if {"$type" == "varchar" || "$type" == "text"} {
	      lappend list $field
	    } else {
	      lappend list TEXT($field)
	    }
	  }
	}
	set vars(_key) [join $list "||':'||"]
      }
    }

    foreach field $raw_fields {
      if {"$field" == "_key"} {
	set key $vars(_key)
      } else {
	lappend fields $field
      }
      if [info exists params($field)] {
        set field2sql($field) $params($field)
	unset params($field)
      }
    }

    if ![info exists key] {
      set key [lindex $fields 0]
      # set fields [lrange $fields 1 end]
    }

    set ns ::sttp::sqltable[incr sqltable_seq]

    namespace eval $ns {
      proc ctable {args} {
	set level [expr {[info level] - 1}]
	eval [list ::sttp::sql_ctable $level [namespace current]] $args
      }

      # copy the search proc into this namespace
      proc search_to_sql [info args ::sttp::search_to_sql] [info body ::sttp::search_to_sql]
    }

    set ${ns}::table_name $table
    array set ${ns}::sql [array get field2sql]
    set ${ns}::key $key
    set ${ns}::fields $fields
    array set ${ns}::types [array get field2type]

    return ${ns}::ctable
  }
  register sql connect_pgsql

  variable ctable_commands
  array set ctable_commands {
    get				sql_ctable_get
    set				sql_ctable_set
    array_get			sql_ctable_unimplemented
    array_get_with_nulls	sql_ctable_agwn
    exists			sql_ctable_exists
    delete			sql_ctable_delete
    count			sql_ctable_count
    foreach			sql_ctable_foreach
    type			sql_ctable_type
    import			sql_ctable_unimplemented
    import_postgres_result	sql_ctable_unimplemented
    export			sql_ctable_unimplemented
    fields			sql_ctable_fields
    fieldtype			sql_ctable_fieldtype
    needs_quoting		sql_ctable_needs_quoting
    names			sql_ctable_names
    reset			sql_ctable_unimplemented
    destroy			sql_ctable_destroy
    search			sql_ctable_search
    search+			sql_ctable_search
    statistics			sql_ctable_unimplemented
    write_tabsep		sql_ctable_unimplemented
    read_tabsep			sql_ctable_read_tabsep
    index			sql_ctable_ignore_null
  }
  variable ctable_extended_commands
  array set ctable_extended_commands {
    methods			sql_ctable_methods
    key				sql_ctable_keys
    keys			sql_ctable_keys
    makekey			sql_ctable_make_key
    fetch			sql_ctable_fetch
    store			sql_ctable_store
    perform			sql_ctable_perform
  }

  proc sql_ctable {level ns cmd args} {
    variable ctable_commands
    variable ctable_extended_commands
    if {[info exists ctable_commands($cmd)]} {
      set proc $ctable_commands($cmd)
    } elseif {[info exists ctable_extended_commands($cmd)]} {
      set proc $ctable_extended_commands($cmd)
    } else {
      set proc sql_ctable_unimplemented
    }
    return [eval [list $proc $level $ns $cmd] $args]
  }

  proc sql_ctable_perform {level ns cmd _req args} {
    upvar #$level $_req req
    array set tmp [array get req]
    array set tmp $args
    if [info exists tmp(-count)] {
      set result_var $tmp(-count)
      unset tmp(-count)
    }
    lappend list sql_ctable_search $level $ns search
    set list [concat $list [array get tmp]]
    set result [eval $list]
    if [info exists result_var] {
      uplevel #$level [list set $result_var $result]
    }
    return $result
  }

  proc sql_ctable_methods {level ns cmd args} {
    variable ctable_commands
    variable ctable_extended_commands
    return [
      lsort [
        concat [array names ctable_commands] \
	       [array names ctable_extended_commands]
      ]
    ]
  }

  proc sql_ctable_keys {level ns cmd args} {
    return [set ${ns}::key]
  }

  proc sql_ctable_make_key {level ns cmd args} {
    set err_name "list"
    if {[llength $args] == 1} {
      set err_name [lindex $args 0]
      set args [uplevel #$level array get [lindex $args 0]]
    }
    array set array $args
    set key [set ${ns}::key]
    if [info exists array($key)] {
      return $array($key)
    }
    return -code error "No key in $err_name"
  }

  proc sql_ctable_unimplemented {level ns cmd args} {
    return -code error "Unimplemented command $cmd"
  }

  proc sql_ctable_ignore_null {args} {
    return ""
  }

  proc sql_ctable_ignore_true {args} {
    return 1
  }

  proc sql_ctable_ignore_false {args} {
    return 0
  }

  proc sql_ctable_get {level ns cmd val args} {
    if ![llength $args] {
      set args [set ${ns}::fields]
    }
    foreach arg $args {
      if [info exists ${ns}::sql($arg)] {
	lappend select [set ${ns}::sql($arg)]
      } else {
	lappend select $arg
      }
    }
    set sql "SELECT [join $select ,] FROM [set ${ns}::table_name]"
    append sql " WHERE [set ${ns}::key] = [pg_quote $val]"
    append sql " LIMIT 1;"
    return [sql_get_one_tuple $sql]
  }

  proc sql_ctable_agwn {level ns cmd val args} {
    if ![llength $args] {
      set args [set ${ns}::fields]
    }
    set vals [eval [list sql_ctable_get $level $ns $cmd $val] $args]
    foreach arg $args val $vals {
      lappend result $arg $val
    }
    return $result
  }

  proc sql_ctable_fetch {level ns cmd key _a args} {
    upvar #$level $_a a
    if [catch {
      set list [eval [list sql_ctable_agwn $level $ns $cmd $key] $args]
    } err] {
      return 0
    }
    array set a $list
    return 1
  }

  proc sql_ctable_exists {level ns cmd val} {
    set sql "SELECT [set ${ns}::key] FROM [set ${ns}::table_name]"
    append sql " WHERE [set ${ns}::key] = [pg_quote $val]"
    append sql " LIMIT 1;"
    # debug "\[pg_exec \[conn] \"$sql\"]"

    set pg_res [pg_exec [conn] $sql]
    if {![set ok [string match "PGRES_*_OK" [pg_result $pg_res -status]]]} {
      set err [pg_result $pg_res -error]
      set errinf "$err\nIn $sql"
    } else {
      set result [pg_result $pg_res -numTuples]
    }
    pg_result $pg_res -clear

    if !$ok {
      return -code error -errorinfo $errinf $err
    }
    return $result
  }

  proc sql_ctable_count {level ns cmd args} {
    set sql "SELECT COUNT([set ${ns}::key]) FROM [set ${ns}::table_name]"
    if {[llength $args] == 1} {
      append sql " WHERE [set ${ns}::key] = [pg_quote $val]"
    }
    append sql ";"
    return [lindex [sql_get_one_tuple $sql] 0]
  }

  proc sql_ctable_fields {level ns cmd args} {
    return [set ${ns}::fields]
  }

  proc sql_ctable_type {level ns cmd args} {
    return sql:///[set ${ns}::table_name]
  }

  proc sql_ctable_fieldtype {level ns cmd field} {
    if ![info exists ${ns}::types($field)] {
      return -code error "No such field: $field"
    }
    return [set ${ns}::types($field)]
  }

  proc sql_ctable_search {level ns cmd args} {
    array set search $args
    if [info exists search(-array_get)] {
      return -code error "Unimplemented: search -array_get"
    }
    if [info exists search(-array)] {
      return -code error "Unimplemented: search -array"
    }
    if {[info exists search(-countOnly)] && $search(-countOnly) == 0} {
      unset search(-countOnly)
    }
    if {[info exists search(-countOnly)] && ![info exists search(-code)]} {
      return -code error "Must provide -code or -countOnly"
    }
    set sql [${ns}::search_to_sql search]
    if [info exists search(-countOnly)] {
      return [lindex [sql_get_one_tuple $sql] 0]
    }
    set code {}
    set array __array
    if [info exists search(-array_with_nulls)] {
      set array $search(-array_with_nulls)
    }
    if [info exists search(-array_get_with_nulls)] {
      lappend code "set $search(-array_get_with_nulls) \[array get $array]"
    }
    if [info exists search(-key)] {
      lappend code "set $search(-key) \$${array}(__key)"
    }
    lappend code $search(-code)
    # debug [list pg_select [conn] $sql $array [join $code "\n"]]
    uplevel #$level [list pg_select [conn] $sql $array [join $code "\n"]]
  }

  proc sql_ctable_foreach {level ns cmd keyvar value code} {
    set sql "SELECT [set ${ns}::key] FROM [set ${ns}::table_name]"
    append sql " WHERE [set ${ns}::key] ILIKE [::sttp::quote_glob $val];"
    set code "set $keyvar \[lindex $__key 0]\n$code"
    uplevel #$level [list pg_select [conn] $sql __key $code]
  }

  proc sql_ctable_destroy {level ns cmd args} {
    namespace delete $ns
  }

  proc sql_ctable_delete {level ns cmd key args} {
    set sql "DELETE FROM [set ${ns}::table_name] WHERE [set ${ns}::key] = [pg_quote $key];"
    return [exec_sql $sql]
  }

  proc sql_ctable_set {level ns cmd key args} {
    if ![llength $args] {
      return
    }
    if {[llength $args] == 1} {
      set args [lindex $args 0]
    }
    foreach {col value} $args {
      if [info exists ${ns}::sql($col)] {
	set col [set ${ns}::sql($col)]
      }
      lappend assigns "$col = [pg_quote $value]"
      lappend cols $col
      lappend vals [pg_quote $value]
    }
    set sql "UPDATE [set ${ns}::table_name] SET [join $assigns ", "]"
    append sql " WHERE [set ${ns}::key] = [pg_quote $key];"
    set rows 0
    if ![exec_sql_rows $sql rows] {
      return 0
    }
    if {$rows > 0} {
      return 1
    }
    set sql "INSERT INTO [set ${ns}::table_name] ([join $cols ","]) VALUES ([join $vals ","]);"
    return [exec_sql $sql]
  }

  proc sql_ctable_store {level ns cmd _array args} {
    upvar #$level $_array array
    set key [sql_ctable_make_key $level $ns $cmd $_array]
    return [
      eval [list sql_ctable_set $level $ns $cmd $key] [array get array] $args
    ]
  }

  proc sql_ctable_needs_quoting {level ns cmd args} { sql_ctable_unimplemented }
  proc sql_ctable_names {level ns cmd args} { sql_ctable_unimplemented }
  proc sql_ctable_read_tabsep {level ns cmd args} { sql_ctable_unimplemented }

  #
  # This is never evaluated directly, it's only copied into a namespace
  # with [info body], so variables are from $ns and anything in ::sttp
  # needs direct quoting
  #
  proc search_to_sql {_req} {
    upvar 1 $_req req
    variable key
    variable table_name
    variable fields

    set select {}
    if [info exists req(-countOnly)] {
      lappend select "COUNT($key) AS count"
    } else {
      if [info exists req(-key)] {
	if [info exists sql($key)] {
	  lappend select "$sql($key) AS __key"
	} else {
          lappend select "$key AS __key"
	}
      }
      if [info exists req(-fields)] {
        set cols $req(fields)
      } else {
        set cols $fields
      }
  
      foreach col $cols {
        if [info exists sql($col)] {
	  lappend select "$sql($col) AS $col"
        } else {
	  lappend select $col
        }
      }
    }
  
    set where {}
    if [info exists req(-glob)] {
      lappend where "$key LIKE [quote_glob $req(-glob)]"
    }
  
    if [info exists req(-compare)] {
      foreach tuple $req(-compare) {
	foreach {op col v1 v2} $tuple break
	if [info exists types($col)] {
	  set type $types($col)
	} else {
	  set type varchar
	}
	set q1 [pg_quote $v1]
	set q2 [pg_quote $v2]
  
	if [info exists sql($col)] {
	  set col $sql($col)
	}
	switch -exact -- [string tolower $op] {
	  false { lappend where "$col = FALSE" }
	  true { lappend where "$col = TRUE" }
	  null { lappend where "$col IS NULL" }
	  notnull { lappend where "$col IS NOT NULL" }
	  < { lappend where "$col < $q1" }
	  <= { lappend where "$col <= $q1" }
	  = { lappend where "$col = $q1" }
	  != { lappend where "$col <> $q1" }
	  <> { lappend where "$col <> $q1" }
	  >= { lappend where "$col >= $q1" }
	  > { lappend where "$col > $q1" }

	  imatch { lappend where "$col ILIKE [::sttp::quote_glob $v1]" }
	  -imatch { lappend where "NOT $col ILIKE [::sttp::quote_glob $v1]" }

	  match { lappend where "$col ILIKE [::sttp::quote_glob $v1]" }
	  notmatch { lappend where "NOT $col ILIKE [::sttp::quote_glob $v1]" }

	  xmatch { lappend where "$col LIKE [::sttp::quote_glob $v1]" }
	  -xmatch { lappend where "NOT $col LIKE [::sttp::quote_glob $v1]" }

	  match_case { lappend where "$col LIKE [::sttp::quote_glob $v1]" }
	  notmatch_case {
	    lappend where "NOT $col LIKE [::sttp::quote_glob $v1]"
	  }

	  umatch {
	    lappend where "$col LIKE [::sttp::quote_glob [string toupper $v1]]"
	  }
	  -umatch {
	    lappend where "NOT $col LIKE [
				::sttp::quote_glob [string toupper $v1]]"
	  }

	  lmatch {
	    lappend where "$col LIKE [::sttp::quote_glob [string tolower $v1]]"
	  }
	  -lmatch {
	    lappend where "NOT $col LIKE [
				::sttp::quote_glob [string tolower $v1]]"
	  }

	  range {
	    lappend where "$col >= $q1"
	    lappend where "$col < [pg_quote $v2]"
	  }
	  in {
	    foreach v [lrange $tuple 2 end] {
	      lappend q [pg_quote $v]
	    }
	    lappend where "$col IN ([join $q ","])"
	  }
	}
      }
    }
  
    set order {}
    if [info exists req(-sort)] {
      foreach field $req(-sort) {
	set desc ""
	if [regexp {^-(.*)} $field _ field] {
	  set desc " DESC"
	}
	if [info exists sql(field)] {
	  lappend order "$sql($field)$desc"
	} else {
	  lappend order "$field$desc"
	}
      }
    }
  
    set sql "SELECT [join $select ","] FROM $table_name"
    if [llength $where] {
      append sql " WHERE [join $where " AND "]"
    }
    if [llength $order] {
      append sql " ORDER BY [join $order ","]"
    }
    if [info exists req(-limit)] {
      append sql " LIMIT $req(-limit)"
    }
    if [info exists req(-offset)] {
      append sql " OFFSET $req(-offset)"
    }
    append sql ";"
  
    return $sql
  }

  proc sql_get_one_tuple {req} {
    set pg_res [pg_exec [conn] $req]
    if {![set ok [string match "PGRES_*_OK" [pg_result $pg_res -status]]]} {
      set err [pg_result $pg_res -error]
    } elseif {[pg_result $pg_res -numTuples] == 0} {
      set ok 0
      set err "No match"
    } else {
      set result [pg_result $pg_res -getTuple 0]
    }
    pg_result $pg_res -clear

    if !$ok {
      set errinf "$err\nIn $req"
      return -code error -errorinfo $errinf $err
    }

    return $result
  }

  proc quote_glob {pattern} {
    regsub -all {[%_]} $pattern {\\&} pattern
    regsub -all {@} $pattern {@%} pattern
    regsub -all {\\[*]} $pattern @_ pattern
    regsub -all {[*]} $pattern "%" pattern
    regsub -all {@_} $pattern {*} pattern
    regsub -all {\\[?]} $pattern @_ pattern
    regsub -all {[?]} $pattern "_" pattern
    regsub -all {@_} $pattern {?} pattern
    regsub -all {@%} $pattern {@} pattern
    return [pg_quote $pattern]
  }

  # Helper routine to shortcut the business of creating a URI and connecting
  # with the same keys. Using this implicitly pulls in sttpx inside connect
  # if it hasn't already been pulled in.
  #
  # Eg: ::sttp::connect_sql my_table {index} -cols {index name value}
  #
  proc connect_sql {table keys args} {
    lappend make make_sql_uri $table -keys $keys
    set uri [eval $make $args]
    return [connect $uri -keys $keys]
  }
}

package provide sttp_client_postgres 1.0
