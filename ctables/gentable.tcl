#
# CTables - code to generate Tcl C extensions that implement tables out of
# C structures
#
#
# $Id$
#

namespace eval ctable {
    variable ctablePackageVersion
    variable table
    variable tables
    variable booleans
    variable nonBooleans
    variable fields
    variable fieldList
    variable ctableTypes
    variable ctableErrorInfo
    variable withPgtcl
    variable reservedWords
    variable errorDebug

    variable genCompilerDebug
    variable showCompilerCommands
    variable memDebug
    variable targetDir
    variable pgTargetDir

    set ctablePackageVersion 1.3

    # set to 1 to see errorInfo in normal tracebacks
    set errorDebug 0

    # set to 1 to build with debugging and link to tcl debugging libraries
    set genCompilerDebug 0
    set showCompilerCommands 0
    set memDebug 0

    set targetDir /usr/local
    set pgTargetDir /usr/local

    variable pgtcl_ver 1.5

    variable leftCurly
    variable rightCurly

    set leftCurly \173
    set rightCurly \175

    set ctableErrorInfo ""

    if {$tcl_platform(os) == "Darwin"} {
       set withPgtcl 0
    } else {
       set withPgtcl 1
    }

    set tables ""

    namespace eval fields {}

    set cvsID {#CTable generator ID: $Id$}

    ## ctableTypes must line up with the enumerated typedef "ctable_types"
    ## in ctable.h
    set ctableTypes "boolean fixedstring varstring char mac short int long wide float double inet tclobj key"

    set reservedWords "bool char short int long wide float double"

if {![info exists srcDir]} {
    set srcDir .
}

set fp [open $srcDir/template.c-subst]
set metaTableSource [read $fp]
close $fp

set fp [open $srcDir/init-exten.c-subst]
set initExtensionSource [read $fp]
close $fp

set fp [open $srcDir/exten-frag.c-subst]
set extensionFragmentSource [read $fp]
close $fp

#
# cmdBodySource - code we run subst over to generate the second chunk of the
#  body that implements the methods that work on the table.
#
set fp [open $srcDir/command-body.c-subst]
set cmdBodySource [read $fp]
close $fp

#
# emit - emit a string to the file being generated
#
proc emit {text} {
    variable ofp

    puts $ofp $text
}

#
# cquote -- quote a string so the C compiler will see the same thing
#  if it occurs inside double-quotes
#
proc cquote {string} {
  # first, escape the metacharacters \ and "
  regsub -all {["\\]} $string {\\&} string

  # Now loop over the string looking for nonprinting characters
  set quoted ""
  while {
    [regexp {([[:graph:]]*)([^[:graph:]])(.*)} $string _ plain char string]
  } {
    append quoted $plain
    # gratuitously make \n and friends look nice
    set index [string first $char "\r\n\t\b\f "]
    if {$index == -1} {
      scan $char %c decimal
      set plain [format {\%03o} $decimal]
    } else {
      set plain [lindex {{\r} {\n} {\t} {\b} {\f} { }} $index]
    }
    append quoted $plain
  }
  append quoted $string
  return $quoted
}

#
# Special normally-illegal field names
#
variable specialFieldNames {
    _key
}

#
# is_key - is this field a "key" or a normal field
#
proc is_key {fieldName} {
    # If called before special "_key" field is set up.
    if {"$fieldName" == "_key"} {
	return 1
    }

    # Otherwise go by type
    upvar ::ctable::fields::$fieldName field
    if {[info exists field(type)] && "$field(type)" == "key"} {
	return 1
    }

    return 0
}

#
# is_hidden - hidden fields are not returned in arrays or lists by default
#
proc is_hidden {fieldName} {
    return [string match ".*" $fieldName]
}

#
# field_to_enum - return a field mapped to the name we'll use when
#  creating or referencing an enumerated list of field names.
#
#  for example, creating table fa_position and field longitude, this
#   routine will return FIELD_FA_POSITION_LONGITUDE
#
proc field_to_enum {fieldName} {
    variable table

    if {[regexp {^[.](.*)$} $fieldName _ pseudoName]} {
	return "[string toupper $pseudoName]_[string toupper $table]"
    }
    return "FIELD_[string toupper $table]_[string toupper $fieldName]"
}

#
# field_to_var - generate a unique variable name
#
proc field_to_var {table fieldName varName} {
    if [regexp {^[.](.*)} $fieldName _ pseudoName] {
	return "_${table}_${pseudoName}_$varName"
    }
    return "${table}_${fieldName}_$varName"
}
#
# field_to_nameObj - return a field mapped to the Tcl name object we'll
# use to expose the name to Tcl
#
proc field_to_nameObj {table fieldName} {
    return [field_to_var $table $fieldName nameObj]
}

#
# preambleCannedSource -- stuff that goes at the start of the file we generate
#
set preambleCannedSource {
#include "ctable.h"
}

set nullIndexDuringSetSource {
	        if (ctable->skipLists[field] != NULL) {
		    if (indexCtl == CTABLE_INDEX_NORMAL) {
		        ctable_RemoveFromIndex (ctable, row, field);
		    }

		    if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable_InsertNullIntoIndex (interp, ctable, row, field) == TCL_ERROR)) {
		        return TCL_ERROR;
		    }
		}
}

#
# nullCheckDuringSetSource - standard stuff for handling nulls during set
#
set nullCheckDuringSetSource {
	if (${table}_obj_is_null (obj)) {
	    if (!row->_${fieldName}IsNull) {
$handleNullIndex
	        // field wasn't null but now is
		row->_${fieldName}IsNull = 1;
		// row->_dirty = 1;
	    }
	    break;
	}
}

#
# gen_null_check_during_set_source - generate standard null checking
#  for a set
#
proc gen_null_check_during_set_source {table fieldName} {
    variable nullCheckDuringSetSource
    variable nullIndexDuringSetSource
    variable fields

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(indexed)] && $field(indexed)} {
        set handleNullIndex $nullIndexDuringSetSource
    } else {
        set handleNullIndex ""
    }

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
	return [string range [subst -nobackslashes -nocommands $nullCheckDuringSetSource] 1 end-1]
    }
}

set unsetNullDuringSetSource {
	if (row->_${fieldName}IsNull) {
	    row->_${fieldName}IsNull = 0;

	    if ((indexCtl == CTABLE_INDEX_NORMAL) && (ctable->skipLists[field] != NULL)) {
	        indexCtl = CTABLE_INDEX_NEW; // inhibit a second removal
		if (ctable_RemoveNullFromIndex (interp, ctable, row, field) == TCL_ERROR) {
		    return TCL_ERROR;
		}
	    }
	}
}

set unsetNullDuringSetSource_unindexed {
	if (row->_${fieldName}IsNull) {
	    row->_${fieldName}IsNull = 0;
	}
}

#
# gen_unset_null_during_set_source - generate standard null unsetting
#  for a set
#
proc gen_unset_null_during_set_source {table fieldName} {
    variable unsetNullDuringSetSource
    variable unsetNullDuringSetSource_unindexed
    variable fields

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
	if {[info exists field(indexed)] && $field(indexed)} {
	    return [string range [subst -nobackslashes -nocommands $unsetNullDuringSetSource] 1 end-1]
	} else {
	    return [string range [subst -nobackslashes -nocommands $unsetNullDuringSetSource_unindexed] 1 end-1]
	}
    }
}

#####
#
# Generating Code To Set Values In Rows
#
#####

set removeFromIndexSource {
	    if ((indexCtl == CTABLE_INDEX_NORMAL) && (ctable->skipLists[field] != NULL)) {
		ctable_RemoveFromIndex (ctable, row, field);
	    }
}

#
# gen_ctable_remove_from_index - return code to remove the specified field
# from an index, or nothing if the field is not indexable -- requires
# interp, ctable, row and field to be defined and in scope in the C target.
#
proc gen_ctable_remove_from_index {fieldName} { 
    variable fields
    variable removeFromIndexSource

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(indexed)] && $field(indexed)} {
        return $removeFromIndexSource
    } else {
        return ""
    }
    
}

set insertIntoIndexSource {
	if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable->skipLists[field] != NULL)) {
	    if (ctable_InsertIntoIndex (interp, ctable, row, field) == TCL_ERROR) {
	        return TCL_ERROR;
	    }
	}
}

#
# gen_ctable_insert_into_index - return code to insert the specified field
# into an index, or nothing if the field is not indexable -- requires
# interp, ctable, row and field to be defined and in scope in the C target.
#
proc gen_ctable_insert_into_index {fieldName} { 
    variable fields
    variable insertIntoIndexSource

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(indexed)] && $field(indexed)} {
        return $insertIntoIndexSource
    } else {
        return ""
    }
}

#
# boolSetSource - code we run subst over to generate a set of a boolean (bit)
#
set boolSetSource {
      case $optname: {
        int boolean;

[gen_null_check_during_set_source $table $fieldName]
        if (Tcl_GetBooleanFromObj (interp, obj, &boolean) == TCL_ERROR) {
            Tcl_AppendResult (interp, " while converting $fieldName", (char *)NULL);
            return TCL_ERROR;
        }
[gen_unset_null_during_set_source $table $fieldName]
        row->$fieldName = boolean;
      }
}

#
# numberSetSource - code we run subst over to generate a set of a standard
#  number such as an integer, long, double, and wide integer.  (We have to 
#  handle shorts and floats specially due to type coercion requirements.)
#
set numberSetSource {
      case $optname: {
        $typeText value;
[gen_null_check_during_set_source $table $fieldName]
	if ($getObjCmd (interp, obj, &value) == TCL_ERROR) {
	    Tcl_AppendResult (interp, " while converting $fieldName", (char *)NULL);
	    return TCL_ERROR;
	}
[gen_unset_null_during_set_source $table $fieldName] else if (row->$fieldName == value) {
	    return TCL_OK;
	}
[gen_ctable_remove_from_index $fieldName]
	row->$fieldName = value;
[gen_ctable_insert_into_index $fieldName]
	break;
      }
}

set keySetSource {
      case $optname: {
	Tcl_AppendResult (interp, "Can not assign to $fieldName", (char *)NULL);
	return TCL_ERROR;
      }
}

#
# varstringSetSource - code we run subst over to generate a set of a string.
#
# strings are char *'s that we manage automagically.
#
# Get the string from the passed-in object.  If the length of the string
# matches the length of the default string, see if the length of the
# default string is zero or if obj's string matches the default string.
# If so, set the char * field in the row to NULL.  Upon a fetch of the
# field, we'll provide the default string.
#
# Otherwise allocate space for the new string value and copy it in.
#
set varstringSetSource {
      case $optname: {
	char *string = NULL;
	int   length;
[gen_null_check_during_set_source $table $fieldName]
[gen_unset_null_during_set_source $table $fieldName]
	string = Tcl_GetStringFromObj (obj, &length);
	if ((length == $defaultLength) && (($defaultLength == 0) || (strncmp (string, "$default", $defaultLength) == 0))) {
	    if (row->$fieldName != (char *) NULL) {
		// string was something but now matches the empty string
[gen_ctable_remove_from_index $fieldName]
		ckfree ((void *)row->$fieldName);

		// It's a change to the be default string. If we're
		// indexed, force the default string in there so the 
		// compare routine will be happy and then insert it.
		// can't use our proc here yet because of the
		// default empty string obj fanciness
		if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable->skipLists\[field] == NULL)) {
		    row->$fieldName = Tcl_GetStringFromObj (${table}_DefaultEmptyStringObj, &row->_${fieldName}Length);
		    if (ctable_InsertIntoIndex (interp, ctable, row, field) == TCL_ERROR) {
			return TCL_ERROR;
		    }
		}
		row->$fieldName = NULL;
		row->_${fieldName}AllocatedLength = 0;
		row->_${fieldName}Length = 0;
	    }
	    break;
	}

	// previous field isn't null and new field isn't null and
	// isn't the default string

	// are they feeding us what we already have, we're outta here
	if ((length == row->_${fieldName}Length) && (*row->$fieldName == *string) && (strncmp (row->$fieldName, string, length) == 0)) break;

	// previous field isn't null, new field isn't null, isn't
	// the default string, and isn't the same as the previous field
[gen_ctable_remove_from_index $fieldName]

	// new string value
	// if the allocated length is less than what we need, get more,
	// else reuse the previously allocagted space
	if (row->_${fieldName}AllocatedLength <= length) {
	    if (row->$fieldName != NULL) {
		ckfree ((void *)row->$fieldName);
	    }
	    row->$fieldName = ckalloc (length + 1);
	    row->_${fieldName}AllocatedLength = length + 1;
	}
	strncpy (row->$fieldName, string, length + 1);
	row->_${fieldName}Length = length;

	// if we got here and this field has an index, we've removed
	// the old index either by removing a null index or by
	// removing the prior index, now insert the new index
[gen_ctable_insert_into_index $fieldName]
	break;
      }
}

#
# charSetSource - code we run subst over to generate a set of a single char.
#
set charSetSource {
      case $optname: {
	char *string;
[gen_null_check_during_set_source $table $fieldName]
	string = Tcl_GetString (obj);
	row->$fieldName = string\[0\];
[gen_unset_null_during_set_source $table $fieldName]
	break;
      }
}

#
# fixedstringSetSource - code we run subst over to generate a set of a 
# fixed-length string.
#
set fixedstringSetSource {
      case $optname: {
	char *string;
[gen_null_check_during_set_source $table $fieldName]
	string = Tcl_GetString (obj);
[gen_unset_null_during_set_source $table $fieldName] if (strncmp(row->$fieldName, string, $length) == 0) {
	    return TCL_OK;
	}
[gen_ctable_remove_from_index $fieldName]
	strncpy (row->$fieldName, string, $length);
[gen_ctable_insert_into_index $fieldName]
	break;
      }
}

#
# inetSetSource - code we run subst over to generate a set of an IPv4
# internet address.
#
set inetSetSource {
      case $optname: {
        struct in_addr value;
[gen_null_check_during_set_source $table $fieldName]
	if (!inet_aton (Tcl_GetString (obj), &value)) {
	    Tcl_AppendResult (interp, "expected IP address but got \\"", Tcl_GetString (obj), "\\" parsing field \\"$fieldName\\"", (char *)NULL);
	    return TCL_ERROR;
	}
[gen_unset_null_during_set_source $table $fieldName] else if (memcmp (&row->$fieldName, &value, sizeof (struct in_addr)) == 0) {
            return TCL_OK;
	}

[gen_ctable_remove_from_index $fieldName]
	row->$fieldName = value;
[gen_ctable_insert_into_index $fieldName]
	break;
      }
}

#
# macSetSource - code we run subst over to generate a set of an ethernet
# MAC address.
#
set macSetSource {
      case $optname: {
        struct ether_addr *mac;
[gen_null_check_during_set_source $table $fieldName]
	mac = ether_aton (Tcl_GetString (obj));
	if (mac == (struct ether_addr *) NULL) {
	    Tcl_AppendResult (interp, "expected MAC address but got \\"", Tcl_GetString (obj), "\\" parsing field \\"$fieldName\\"", (char *)NULL);
	    return TCL_ERROR;
	}

[gen_unset_null_during_set_source $table $fieldName] else if (memcmp (&row->$fieldName, mac, sizeof (struct ether_addr)) == 0) {
            return TCL_OK;
        }
[gen_ctable_remove_from_index $fieldName]
	row->$fieldName = *mac;
[gen_ctable_insert_into_index $fieldName]
	break;
      }
}

#
# tclobjSetSource - code we run subst over to generate a set of a tclobj.
#
# tclobjs are Tcl_Obj *'s that we manage automagically.
#
set tclobjSetSource {
      case $optname: {

	if (row->$fieldName != (Tcl_Obj *) NULL) {
	    Tcl_DecrRefCount (row->$fieldName);
	    row->$fieldName = NULL;
	}
[gen_null_check_during_set_source $table $fieldName]
	row->$fieldName = obj;
	Tcl_IncrRefCount (obj);
[gen_unset_null_during_set_source $table $fieldName]
	break;
      }
}

#####
#
# Generating Code For Sort Comparisons
#
#####

#
# nullSortSource - code to be inserted when null values are permitted for the
#  field
#
set nullSortSource {
        if (row1->_${fieldName}IsNull) {
	    if (row2->_${fieldName}IsNull) {
	        return 0;
	    }

	    return direction;
	} else if (row2->_${fieldName}IsNull) {
	    return -direction;
	}
}

#
# gen_null_check_during_sort_comp - emit null checking as part of field
#  comparing in a sort
#
proc gen_null_check_during_sort_comp {table fieldName} {
    variable nullSortSource

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
	return [string range [subst -nobackslashes -nocommands $nullSortSource] 1 end-1]
    }
}

set nullExcludeSource {
	      if (row->_${fieldName}IsNull) {
		  exclude = 1;
		  break;
	      }
}

proc gen_null_exclude_during_sort_comp {table fieldName} {
    variable nullExcludeSource

    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
	return [string range [subst -nobackslashes -nocommands $nullExcludeSource] 1 end-1]
    }
}

#
# boolSortSource - code we run subst over to generate a compare of a 
# boolean (bit) for use in a sort.
#
set boolSortSource {
	case $fieldEnum: {
[gen_null_check_during_sort_comp $table $fieldName]
          if (row1->$fieldName && !row2->$fieldName) {
	      result = -direction;
	      break;
	  }

	  if (!row1->$fieldName && row2->$fieldName) {
	      result = direction;
	  }

	  result = 0;
	  break;
      }
}

#
# numberSortSource - code we run subst over to generate a compare of a standard
#  number such as an integer, long, double, and wide integer for use in a sort.
#
set numberSortSource {
      case $fieldEnum: {
[gen_null_check_during_sort_comp $table $fieldName]
        if (row1->$fieldName < row2->$fieldName) {
	    result = -direction;
	    break;
	}

	if (row1->$fieldName > row2->$fieldName) {
	    result = direction;
	    break;
	}

	result = 0;
	break;
      }
}

#
# varstringSortSource - code we run subst over to generate a compare of 
# a string for use in a sort.
#
set varstringSortSource {
      case $fieldEnum: {
[gen_null_check_during_sort_comp $table $fieldName]
        result = direction * strcmp (row1->$fieldName, row2->$fieldName);
	break;
      }
}

#
# fixedstringSortSource - code we run subst over to generate a comapre of a 
# fixed-length string for use in a sort.
#
set fixedstringSortSource {
      case $fieldEnum: {
[gen_null_check_during_sort_comp $table $fieldName]
        result = direction * strncmp (row1->$fieldName, row2->$fieldName, $length);
	break;
      }
}

#
# binaryDataSortSource - code we run subst over to generate a comapre of a 
# inline binary arrays (inets and mac addrs) for use in a sort.
#
set binaryDataSortSource {
      case $fieldEnum: {
[gen_null_check_during_sort_comp $table $fieldName]
        result = direction * memcmp (&row1->$fieldName, &row2->$fieldName, $length);
	break;
      }
}

#
# tclobjSortSource - code we run subst over to generate a compare of 
# a tclobj for use in a sort.
#
set tclobjSortSource {
      case $fieldEnum: {
        result = direction * strcmp (Tcl_GetString (row1->$fieldName), Tcl_GetString (row2->$fieldName));
	break;
      }
}

#
# keySortSource - code we run subst over to generate a compare of 
# a key for use in a sort.
#
set keySortSource {
      case $fieldEnum: {
        result = direction * strcmp (row1->hashEntry.key, row2->hashEntry.key);
	break;
      }
}

#####
#
# Generating Code For Search Comparisons
#
#####

#
# standardCompNullCheckSource - variable to substitute to do null
# handling in all comparison types
#
set standardCompNullCheckSource {
	  if (row->_${fieldName}IsNull) {
	      if (compType == CTABLE_COMP_NULL) {
		  break;
	      }
	      exclude = 1;
	      break;
          }

	  if (compType == CTABLE_COMP_NULL) {
	      exclude = 1;
	      break;
	  }

	  if (compType == CTABLE_COMP_NOTNULL) {
	      break;
	  }
}

#
# standardCompNotNullCheckSource - variable to substitute to do null
# comparison handling for fields defined notnull.
#
set standardCompNotNullCheckSource {
	  if (compType == CTABLE_COMP_NULL) {
	      exclude = 1;
	      break;
          } else if (compType == CTABLE_COMP_NOTNULL) {
	      break;
	  }
}

#
# gen_standard_comp_null_check_source - gen code to check null stuff
#  when generating search comparison routines
#
proc gen_standard_comp_null_check_source {table fieldName} {
    variable standardCompNullCheckSource
    variable standardCompNotNullCheckSource
    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return [string range $standardCompNotNullCheckSource 1 end-1]
    } else {
	return [string range [subst -nobackslashes -nocommands $standardCompNullCheckSource] 1 end-1]
    }
}

#
# standardCompSwitchSource -stuff that gets emitted in a number of compare
#  routines we generate
#
set standardCompSwitchSource {
          switch (compType) {
	    case CTABLE_COMP_LT:
	        exclude = !(strcmpResult < 0);
		break;

	    case CTABLE_COMP_LE:
	        exclude = !(strcmpResult <= 0);
		break;

	    case CTABLE_COMP_EQ:
	        exclude = !(strcmpResult == 0);
		break;

	    case CTABLE_COMP_NE:
	        exclude = !(strcmpResult != 0);
		break;

	    case CTABLE_COMP_GE:
	        exclude = !(strcmpResult >= 0);
		break;

	    case CTABLE_COMP_GT:
	        exclude = !(strcmpResult > 0);
		break;

	    default:
	        panic ("compare type %d not implemented for field \"${fieldName}\"", compType);
	  }
	  break;
}

#
# gen_standard_comp_switch_source - emit the standard compare source
#
proc gen_standard_comp_switch_source {fieldName} {
    variable standardCompSwitchSource

    return [string range [subst -nobackslashes -nocommands $standardCompSwitchSource] 1 end-1]
}

#
# boolCompSource - code we run subst over to generate a compare of a 
# boolean (bit)
#
set boolCompSource {
      case $fieldEnum: {
[gen_standard_comp_null_check_source $table $fieldName]
	switch (compType) {
	  case CTABLE_COMP_TRUE:
	     exclude = (!row->$fieldName);
	     break;

	  case CTABLE_COMP_FALSE:
	    exclude = row->$fieldName;
	    break;
	}
	break;
      }
}

#
# numberCompSource - code we run subst over to generate a compare of a standard
#  number such as an integer, long, double, and wide integer.  (We have to 
#  handle shorts and floats specially due to type coercion requirements.)
#
set numberCompSource {
        case $fieldEnum: {
[gen_standard_comp_null_check_source $table $fieldName]
          switch (compType) {
	    case CTABLE_COMP_LT:
	        exclude = !(row->$fieldName < row1->$fieldName);
		break;

	    case CTABLE_COMP_LE:
	        exclude = !(row->$fieldName <= row1->$fieldName);
		break;

	    case CTABLE_COMP_EQ:
	        exclude = !(row->$fieldName == row1->$fieldName);
		break;

	    case CTABLE_COMP_NE:
	        exclude = !(row->$fieldName != row1->$fieldName);
		break;

	    case CTABLE_COMP_GE:
	        exclude = !(row->$fieldName >= row1->$fieldName);
		break;

	    case CTABLE_COMP_GT:
	        exclude = !(row->$fieldName > row1->$fieldName);
		break;

	    case CTABLE_COMP_TRUE:
	        exclude = (!row->$fieldName);
		break;

	    case CTABLE_COMP_FALSE:
	        exclude = row->$fieldName;
		break;

	    default:
	        panic ("compare type %d not implemented for field \"${fieldName}\"", compType);
	  }
	  break;
        }
}

#
# varstringCompSource - code we run subst over to generate a compare of 
# a string.
#
set varstringCompSource {
        case $fieldEnum: {
          int     strcmpResult;

[gen_standard_comp_null_check_source $table $fieldName]
	  if ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_NOTMATCH) || (compType == CTABLE_COMP_MATCH_CASE) || (compType == CTABLE_COMP_NOTMATCH_CASE)) {
[gen_null_exclude_during_sort_comp $table $fieldName]
	      // matchMeansKeep will be 1 if matching means keep,
	      // 0 if it means discard
	      int matchMeansKeep = ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_MATCH_CASE));
	      struct ctableSearchMatchStruct *sm = component->clientData;

	      if (sm->type == CTABLE_STRING_MATCH_ANCHORED) {
		  char *field;
		  char *match;

		  exclude = !matchMeansKeep;
		  for (field = row->$fieldName, match = row1->$fieldName; *match != '*' && *match != '\0'; match++, field++) {
		      // printf("comparing '%c' and '%c'\n", *field, *match);
		      if (sm->nocase) {
			  if (tolower (*field) != tolower (*match)) {
			      exclude = matchMeansKeep;
			      break;
			  }
		      } else {
			  if (*field != *match) {
			      exclude = matchMeansKeep;
			      break;
			  }
		      }
		  }
		  // if we got here it was anchored and we now know the score
		  break;
	      } else if (sm->type == CTABLE_STRING_MATCH_UNANCHORED) {
	          exclude = (boyer_moore_search (sm, (unsigned char *)row->$fieldName, row->_${fieldName}Length, sm->nocase) == NULL);
		  if (!matchMeansKeep) exclude = !exclude;
		  break;
	      } else if (sm->type == CTABLE_STRING_MATCH_PATTERN) {
	          exclude = !(Tcl_StringCaseMatch (row->$fieldName, row1->$fieldName, ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_NOTMATCH))));
		  if (!matchMeansKeep) exclude = !exclude;
		  break;
              } else {
		  panic ("software bug, sm->type unknown match type");
	      }
	  }

          strcmpResult = strcmp (row->$fieldName, row1->$fieldName);
[gen_standard_comp_switch_source $fieldName]
        }
}

#
# fixedstringCompSource - code we run subst over to generate a comapre of a 
# fixed-length string.
#
set fixedstringCompSource {
        case $fieldEnum: {
          int     strcmpResult;

[gen_standard_comp_null_check_source $table $fieldName]
          strcmpResult = strncmp (row->$fieldName, row1->$fieldName, $length);
[gen_standard_comp_switch_source $fieldName]
        }
}

#
# binaryDataCompSource - code we run subst over to generate a comapre of a 
# binary data.
#
set binaryDataCompSource {
        case $fieldEnum: {
          int              strcmpResult;

[gen_standard_comp_null_check_source $table $fieldName]
          strcmpResult = memcmp ((void *)&row->$fieldName, (void *)&row1->$fieldName, $length);
[gen_standard_comp_switch_source $fieldName]
        }
}

#
# tclobjCompSource - code we run subst over to generate a compare of 
# a tclobj for use in a search.
#
# this could be so wrong - there may be a way to keep it from generating
# the text -- right now we are doing a Tcl_GetStringFromObj in the
# routine that sets this up, maybe don't do that and figure out some
# way to compare objects (?)
#
set tclobjCompSource {
        case $fieldEnum: {
          int      strcmpResult;

[gen_standard_comp_null_check_source $table $fieldName]
          strcmpResult = strcmp (Tcl_GetString (row->$fieldName), Tcl_GetString (row1->$fieldName));
[gen_standard_comp_switch_source $fieldName]
        }
}

#
# keyCompSource - code we run subst over to generate a compare of 
# a string.
#
set keyCompSource {
        case $fieldEnum: {
          int     strcmpResult;

[gen_standard_comp_null_check_source $table $fieldName]
	  if ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_NOTMATCH) || (compType == CTABLE_COMP_MATCH_CASE) || (compType == CTABLE_COMP_NOTMATCH_CASE)) {
[gen_null_exclude_during_sort_comp $table $fieldName]
	      // matchMeansKeep will be 1 if matching means keep,
	      // 0 if it means discard
	      int matchMeansKeep = ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_MATCH_CASE));
	      struct ctableSearchMatchStruct *sm = component->clientData;

	      if (sm->type == CTABLE_STRING_MATCH_ANCHORED) {
		  char *field;
		  char *match;

		  exclude = !matchMeansKeep;
		  for (field = row->hashEntry.key, match = row1->hashEntry.key; *match != '*' && *match != '\0'; match++, field++) {
		      // printf("comparing '%c' and '%c'\n", *field, *match);
		      if (sm->nocase) {
			  if (tolower (*field) != tolower (*match)) {
			      exclude = matchMeansKeep;
			      break;
			  }
		      } else {
			  if (*field != *match) {
			      exclude = matchMeansKeep;
			      break;
			  }
		      }
		  }
		  // if we got here it was anchored and we now know the score
		  break;
	      } else if (sm->type == CTABLE_STRING_MATCH_UNANCHORED) {
	          exclude = (boyer_moore_search (sm, (unsigned char *)row->hashEntry.key, strlen(row->hashEntry.key), sm->nocase) == NULL);
		  if (!matchMeansKeep) exclude = !exclude;
		  break;
	      } else if (sm->type == CTABLE_STRING_MATCH_PATTERN) {
	          exclude = !(Tcl_StringCaseMatch (row->hashEntry.key, row1->hashEntry.key, ((compType == CTABLE_COMP_MATCH) || (compType == CTABLE_COMP_NOTMATCH))));
		  if (!matchMeansKeep) exclude = !exclude;
		  break;
              } else {
		  panic ("software bug, sm->type unknown match type");
	      }
	  }

          strcmpResult = strcmp (row->hashEntry.key, row1->hashEntry.key);
[gen_standard_comp_switch_source $fieldName]
        }
}


#####
#
# Generating Code To Set Fields In Rows
#
#####

set fieldObjSetSource {
struct $table *${table}_make_row_struct () {
    struct $table *row;

    row = (struct $table *)ckalloc (sizeof (struct $table));
    ${table}_init (row);

    return row;
}

struct $table *${table}_find_or_create (CTable *ctable, char *key, int *newPtr) {
    struct $table *row;

    ctable_HashEntry *hashEntry = ctable_InitHashEntry (ctable->keyTablePtr, key, (ctable_HashEntry *(*)())${table}_make_row_struct, newPtr);

    row = (struct $table *)hashEntry;
    if (*newPtr) {
	ctable_ListInsertHead (&ctable->ll_head, (ctable_BaseRow *)row, 0);
	ctable->count++;
	// printf ("created new entry for '%s'\n", key);
    } else {
	// printf ("found existing entry for '%s'\n", key);
    }

    return row;
}

int
${table}_set_fieldobj (Tcl_Interp *interp, CTable *ctable, Tcl_Obj *obj, struct $table *row, Tcl_Obj *fieldObj, int indexCtl)
{
    int field;

    if (Tcl_GetIndexFromObj (interp, fieldObj, ${table}_fields, "field", TCL_EXACT, &field) != TCL_OK) {
        return TCL_ERROR;
    }

    return ${table}_set (interp, ctable, obj, row, field, indexCtl);
}
}

set fieldSetSource {
int
${table}_set (Tcl_Interp *interp, CTable *ctable, Tcl_Obj *obj, struct $table *row, int field, int indexCtl) $leftCurly

    switch ((enum ${table}_fields) field) $leftCurly
}

set fieldObjGetSource {
struct $table *${table}_find (CTable *ctable, char *key) {
    ctable_HashEntry *hashEntry;

    hashEntry = ctable_FindHashEntry (ctable->keyTablePtr, key);
    if (hashEntry == (ctable_HashEntry *) NULL) {
        return (struct $table *) NULL;
    }
    
    return (struct $table *) hashEntry;
}

Tcl_Obj *
${table}_get_fieldobj (Tcl_Interp *interp, struct $table *row, Tcl_Obj *fieldObj)
{
    int field;

    if (Tcl_GetIndexFromObj (interp, fieldObj, ${table}_fields, "field", TCL_EXACT, &field) != TCL_OK) {
        return (Tcl_Obj *)NULL;
    }

    return ${table}_get (interp, row, field);
}

int
${table}_lappend_field (Tcl_Interp *interp, Tcl_Obj *destListObj, void *vPointer, int field)
{
    struct $table *row = vPointer;

    Tcl_Obj *obj = ${table}_get (interp, row, field);

    if (Tcl_ListObjAppendElement (interp, destListObj, obj) == TCL_ERROR) {
        return TCL_ERROR;
    }

    return TCL_OK;
}

int
${table}_lappend_fieldobj (Tcl_Interp *interp, void *vPointer, Tcl_Obj *fieldObj)
{
    struct $table *row = vPointer;
    Tcl_Obj *obj = ${table}_get_fieldobj (interp, row, fieldObj);

    if (obj == NULL) {
        return TCL_ERROR;
    }

    if (Tcl_ListObjAppendElement (interp, Tcl_GetObjResult (interp), obj) == TCL_ERROR) {
        return TCL_ERROR;
    }

    return TCL_OK;
}
}

set lappendFieldAndNameObjSource {
int
${table}_lappend_field_and_name (Tcl_Interp *interp, Tcl_Obj *destListObj, void *vPointer, int field)
{
    struct $table *row = vPointer;
    Tcl_Obj   *obj;

    if (Tcl_ListObjAppendElement (interp, destListObj, ${table}_NameObjList[field]) == TCL_ERROR) {
        return TCL_ERROR;
    }

    obj = ${table}_get (interp, row, field);
    if (Tcl_ListObjAppendElement (interp, destListObj, obj) == TCL_ERROR) {
        return TCL_ERROR;
    }

    return TCL_OK;
}

int
${table}_lappend_field_and_nameobj (Tcl_Interp *interp, void *vPointer, Tcl_Obj *fieldObj)
{
    int        field;

    if (Tcl_GetIndexFromObj (interp, fieldObj, ${table}_fields, "field", TCL_EXACT, &field) != TCL_OK) {
        return TCL_ERROR;
    }

    return ${table}_lappend_field_and_name (interp, Tcl_GetObjResult (interp), vPointer, field); 
}

}

set lappendNonnullFieldAndNameObjSource {
int
${table}_lappend_nonnull_field_and_name (Tcl_Interp *interp, Tcl_Obj *destListObj, void *vPointer, int field)
{
    struct $table *row = vPointer;
    Tcl_Obj   *obj;

    obj = ${table}_get (interp, row, field);
    if (obj == ${table}_NullValueObj) {
        return TCL_OK;
    }

    if (Tcl_ListObjAppendElement (interp, destListObj, ${table}_NameObjList[field]) == TCL_ERROR) {
        return TCL_ERROR;
    }

    if (Tcl_ListObjAppendElement (interp, destListObj, obj) == TCL_ERROR) {
        return TCL_ERROR;
    }

    return TCL_OK;
}

int
${table}_lappend_nonnull_field_and_nameobj (Tcl_Interp *interp, void *vPointer, Tcl_Obj *fieldObj)
{
    int        field;

    if (Tcl_GetIndexFromObj (interp, fieldObj, ${table}_fields, "field", TCL_EXACT, &field) != TCL_OK) {
        return TCL_ERROR;
    }

    return ${table}_lappend_nonnull_field_and_name (interp, Tcl_GetObjResult (interp), vPointer, field);
}

}

set arraySetFromFieldSource {
int
${table}_array_set (Tcl_Interp *interp, Tcl_Obj *arrayNameObj, void *vPointer, int field)
{
    struct $table *row = vPointer;
    Tcl_Obj   *obj;

    obj = ${table}_get (interp, row, field);
    if (obj == ${table}_NullValueObj) {
        // it's null?  unset it from the array, might not be there, ignore error
        Tcl_UnsetVar2 (interp, Tcl_GetString (arrayNameObj), ${table}_fields[field], 0);
        return TCL_OK;
    }

    if (Tcl_ObjSetVar2 (interp, arrayNameObj, ${table}_NameObjList[field], obj, TCL_LEAVE_ERR_MSG) == (Tcl_Obj *)NULL) {
        return TCL_ERROR;
    }

    return TCL_OK;
}

int
${table}_array_set_with_nulls (Tcl_Interp *interp, Tcl_Obj *arrayNameObj, void *vPointer, int field)
{
    struct $table *row = vPointer;
    Tcl_Obj   *obj;

    obj = ${table}_get (interp, row, field);
    if (Tcl_ObjSetVar2 (interp, arrayNameObj, ${table}_NameObjList[field], obj, TCL_LEAVE_ERR_MSG) == (Tcl_Obj *)NULL) {
        return TCL_ERROR;
    }

    return TCL_OK;
}

}

#####
#
# Generating Code To Get Fields From A Rows
#
#####

set fieldGetSource {
Tcl_Obj *
${table}_get (Tcl_Interp *interp, void *vPointer, int field) $leftCurly
    struct $table *row = vPointer;

    switch ((enum ${table}_fields) field) $leftCurly
}

set fieldGetStringSource {
CONST char *
${table}_get_string (const void *vPointer, int field, int *lengthPtr, Tcl_Obj *utilityObj) $leftCurly
    int length;
    const struct $table *row = vPointer;

    if (lengthPtr == (int *) NULL) {
        lengthPtr = &length;
    }

    switch ((enum ${table}_fields) field) $leftCurly
}

#####
#
# Generating Code To Read And Write Tab-Separated Rows
#
#####

set tabSepFunctionsSource {
void
${table}_dstring_append_get_tabsep (char *key, void *vPointer, int *fieldNums, int nFields, Tcl_DString *dsPtr, int noKeys) {
    int              i;
    CONST char      *string;
    int              nChars;
    Tcl_Obj         *utilityObj = Tcl_NewObj();
    struct $table *row = vPointer;

    if (!noKeys) {
	Tcl_DStringAppend (dsPtr, key, -1);
    }

    for (i = 0; i < nFields; i++) {
	if (!noKeys || (i > 0)) {
	    Tcl_DStringAppend (dsPtr, "\t", 1);
	    // Tcl_DStringAppend (dsPtr, "|", 1);
	}

	string = ${table}_get_string (row, fieldNums[i], &nChars, utilityObj);
	if (nChars != 0) {
// printf("${table}_dstring_append_get_tabsep appending '%s'\n", string);
	    Tcl_DStringAppend (dsPtr, string, nChars);
	}
// printf("${table}_dstring_append_get_tabsep i %d fieldNums[i] %d nChars %d\n", i, fieldNums[i], nChars);
    }
    Tcl_DStringAppend (dsPtr, "\n", 1);
    Tcl_DecrRefCount (utilityObj);
}

int
${table}_export_tabsep (Tcl_Interp *interp, CTable *ctable, CONST char *channelName, int *fieldNums, int nFields, char *pattern, int noKeys) {
    Tcl_Channel             channel;
    int                     mode;
    Tcl_DString             dString;
    char                   *key;
    ctable_BaseRow         *row;

    if ((channel = Tcl_GetChannel (interp, channelName, &mode)) == NULL) {
        return TCL_ERROR;
    }

    if ((mode & TCL_WRITABLE) == 0) {
	Tcl_AppendResult (interp, "channel \"", channelName, "\" not writable", (char *)NULL);
        return TCL_ERROR;
    }

    Tcl_DStringInit (&dString);

    CTABLE_LIST_FOREACH (ctable->ll_head, row, 0) {
	// if there's no pattern and no keys has been set, no need to
	// get the key
        if ((pattern == NULL) && noKeys) {
	    key = NULL;
	} else {
	    // key is needed and if there's a pattern, check it
	    key = row->hashEntry.key;
	    if ((pattern != NULL) && (!Tcl_StringCaseMatch (key, pattern, 1))) continue;
	}

        Tcl_DStringSetLength (&dString, 0);

	${table}_dstring_append_get_tabsep (key, (struct ${table} *)row, fieldNums, nFields, &dString, noKeys);

	if (Tcl_WriteChars (channel, Tcl_DStringValue (&dString), Tcl_DStringLength (&dString)) < 0) {
	    Tcl_AppendResult (interp, "write error on channel \"", channelName, "\"", (char *)NULL);
	    Tcl_DStringFree (&dString);
	    return TCL_ERROR;
	}
    }

    Tcl_DStringFree (&dString);
    return TCL_OK;
}

int
${table}_set_from_tabsep (Tcl_Interp *interp, CTable *ctable, char *string, int *fieldIds, int nFields, int noKeys) {
    struct $table *row;
    char          *key;
    char          *field;
    int            indexCtl;
    int            i;
    Tcl_Obj       *utilityObj = Tcl_NewObj ();
    char           keyNumberString[32];

    if (!noKeys) {
	key = strsep (&string, "\t");
    } else {
        sprintf (keyNumberString, "%d", ctable->autoRowNumber++);
	key = keyNumberString;
    }
    row = ${table}_find_or_create (ctable, key, &indexCtl);

    for (i = 0; i < nFields; i++) {
        field = strsep (&string, "\t");
	Tcl_SetStringObj (utilityObj, field, -1);
	if (${table}_set (interp, ctable, utilityObj, row, fieldIds[i], indexCtl) == TCL_ERROR) {
	    Tcl_DecrRefCount (utilityObj);
	    return TCL_ERROR;
	}
    }

    Tcl_DecrRefCount (utilityObj);
    return TCL_OK;
}

int
${table}_import_tabsep (Tcl_Interp *interp, CTable *ctable, CONST char *channelName, int *fieldNums, int nFields, char *pattern, int noKeys) {
    Tcl_Channel      channel;
    int              mode;
    Tcl_Obj         *lineObj = Tcl_NewObj();
    char            *string;
    int              recordNumber = 0;
    char      keyNumberString[32];

    if ((channel = Tcl_GetChannel (interp, channelName, &mode)) == NULL) {
        return TCL_ERROR;
    }

    if ((mode & TCL_READABLE) == 0) {
	Tcl_AppendResult (interp, "channel \"", channelName, "\" not readable", (char *)NULL);
        return TCL_ERROR;
    }

    while (1) {
	char             c;
	char            *strPtr;

        Tcl_SetStringObj (lineObj, "", 0);
        if (Tcl_GetsObj (channel, lineObj) <= 0) break;

	string = Tcl_GetString (lineObj);

	// if pattern exists, see if it does not match key and if so, skip
	if (pattern != NULL) {
	    for (strPtr = string; *strPtr != '\t' && *strPtr != '\0'; strPtr++) continue;
	    c = *strPtr;
	    *strPtr = '\0';
	    if ((pattern != NULL) && (!Tcl_StringCaseMatch (string, pattern, 1))) continue;
	    *strPtr = c;
	}

	if (${table}_set_from_tabsep (interp, ctable, string, fieldNums, nFields, noKeys) == TCL_ERROR) {
	    char lineNumberString[32];

	    Tcl_DecrRefCount (lineObj);
	    sprintf (lineNumberString, "%d", recordNumber + 1);
            Tcl_AppendResult (interp, " while reading line ", lineNumberString, " of input", (char *)NULL);
	    return TCL_ERROR;
	}

	recordNumber++;
    }

    Tcl_DecrRefCount (lineObj);

    if(noKeys)
    {
       sprintf (keyNumberString, "%d", ctable->autoRowNumber - 1);
       Tcl_SetObjResult (interp, Tcl_NewStringObj (keyNumberString, -1));
    }
    return TCL_OK;
}
}

#
# table - the proc that starts defining a table, really, a meta table, and
#  also following it will be the definition of the structure itself
#
proc table {name} {
    variable table
    variable booleans
    variable nonBooleans
    variable fields
    variable fieldList

    set table $name

    set booleans ""
    unset -nocomplain fields
    set fieldList ""
    set nonBooleans ""
}

#
# end_table - proc that declares the end of defining a table - currently does
#  nothing
#
proc end_table {} {
}

#
# Is this a legal field name.
#
# Special fields are automatically legal.
#
proc is_legal {fieldName} {
    variable specialFieldNames
    if {[lsearch $specialFieldNames $fieldName] != -1} {
	return 1
    }
    return [regexp {^[a-zA-Z][_a-zA-Z0-9]*$} $fieldName]
}

#
# deffield - helper for defining fields -- all of the field-defining procs
#  use this except for boolean that subsumes its capabilities, since we
#  need to keep booleans separately for sanity of the C structures
#
#  NB do we really?  i don't know
#
proc deffield {fieldName argList} {
    variable fields
    variable fieldList
    variable nonBooleans
    variable ctableTypes
    variable reservedWords

    if {[lsearch -exact $reservedWords $fieldName] >= 0} {
        error "illegal field name \"$fieldName\" -- it's a reserved word"
    }

    if {![is_legal $fieldName]} {
        error "field name \"$fieldName\" must start with a letter and can only contain letters, numbers, and underscores"
    }

    if {[llength $argList] % 2 != 0} {
        error "number of values in field '$fieldName' definition arguments ('$argList') must be even"
    }

    set fields($fieldName) [linsert $argList 0 name $fieldName]
    array set ::ctable::fields::$fieldName $fields($fieldName)

    lappend fieldList $fieldName
    lappend nonBooleans $fieldName
}

#
# boolean - define a boolean field -- same contents as deffield except it
#  appends to the booleans list instead of the nonBooleans list NB kludge
#
proc boolean {fieldName args} {
    variable booleans
    variable fields
    variable fieldList

    if {![regexp {^[_a-zA-Z][_a-zA-Z0-9]*$} $fieldName]} {
        error "field name \"$fieldName\" must start with a letter and can only contain letters, numbers, and underscores"
    }

    set fields($fieldName) [linsert $args 0 name $fieldName type boolean]
    array set ::ctable::fields::$fieldName $fields($fieldName)

    lappend fieldList $fieldName
    lappend booleans $fieldName
}

#
# fixedstring - define a fixed-length string field
#
proc fixedstring {fieldName length args} {
    array set field $args

    if {[info exists field(default)]} {
        if {[string length $field(default)] != $length} {
	    error "fixedstring \"$fieldName\" default string \"$field(default)\" must match length \"$length\""
	}
    }

    deffield $fieldName [linsert $args 0 type fixedstring length $length needsQuoting 1]
}

#
# varstring - define a variable-length string field
#
proc varstring {fieldName args} {
    deffield $fieldName [linsert $args 0 type varstring needsQuoting 1]
}

#
# char - define a single character field -- this should probably just be
#  fixedstring[1] but it's simpler.  shrug.
#
proc char {fieldName args} {
    deffield $fieldName [linsert $args 0 type char needsQuoting 1]
}

#
# mac - define a mac address field
#
proc mac {fieldName args} {
    deffield $fieldName [linsert $args 0 type mac]
}

#
# short - define a short integer field
#
proc short {fieldName args} {
    deffield $fieldName [linsert $args 0 type short]
}

#
# int - define an integer field
#
proc int {fieldName args} {
    deffield $fieldName [linsert $args 0 type int]
}

#
# long - define a long integer field
#
proc long {fieldName args} {
    deffield $fieldName [linsert $args 0 type long]
}

#
# wide - define a wide integer field -- should always be at least 64 bits
#
proc wide {fieldName args} {
    deffield $fieldName [linsert $args 0 type wide]
}

#
# float - define a floating point field
#
proc float {fieldName args} {
    deffield $fieldName [linsert $args 0 type float]
}

#
# double - define a double-precision floating point field
#
proc double {fieldName args} {
    deffield $fieldName [linsert $args 0 type double]
}

#
# inet - define an IPv4 address field
#
proc inet {fieldName args} {
    deffield $fieldName [linsert $args 0 type inet]
}

#
# tclobj - define an straight-through Tcl_Obj
#
proc tclobj {fieldName args} {
    deffield $fieldName [linsert $args 0 type tclobj needsQuoting 1]
}

#
# key - define a pseudofield for the key
#
proc key {name args} {
    variable key_feild
    # Only allow one key field
    if [info exists key_field] {
	# But only complain if it's not an internal "special" field
	if ![is_special $name] {
	    error "Duplicate key field"
	}
	return
    }
    deffield $name [linsert $args 0 type key needsQuoting 1 notnull 1]
}

#
# putfield - write out a field definition when emitting a C struct
#
proc putfield {type fieldName {comment ""}} {
    if {[string index $fieldName 0] != "*"} {
        set fieldName " $fieldName"
    }

    if {$comment != ""} {
        set comment " /* $comment */"
    }
    emit [format "    %-20s %s;%s" $type $fieldName $comment]
}

#
# ctable_type_to_enum - return a type mapped to the name we use when
#  creating or referencing an enumerated list of ctable types.
#
proc ctable_type_to_enum {type} {
    return "CTABLE_TYPE_[string toupper $type]"
}

#
# gen_ctable_type_stuff - # generate an array of char pointers to the type names
#
proc gen_ctable_type_stuff {} {
    variable ctableTypes
    variable leftCurly
    variable rightCurly

    emit "static char *ctableTypes\[\] = $leftCurly"
    foreach type $ctableTypes {
        emit "    \"$type\","
    }
    emit "    (char *) NULL"
    emit "$rightCurly;"
    emit ""
}

#
# gen_defaults_subr - gen code to set a row to default values
#
proc gen_defaults_subr {subr struct} {
    variable table
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set baseCopy ${struct}_basecopy

    emit "void ${subr}(struct $struct *row) $leftCurly"
    emit "    static int firstPass = 1;"
    emit "    static struct $struct $baseCopy;"
    emit ""
    emit "    if (firstPass) $leftCurly"
    emit "        firstPass = 0;"
    emit ""
    emit "        // $baseCopy.__dirtyIsNull = 0;"
    emit "        // $baseCopy._dirty = 1;"
    emit "       $baseCopy.hashEntry.key = NULL;"

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	switch $field(type) {
	    varstring {
	        emit "        $baseCopy.$fieldName = (char *) NULL;"
		emit "        $baseCopy._${fieldName}Length = 0;"
		emit "        $baseCopy._${fieldName}AllocatedLength = 0;"

		if {![info exists field(notnull)] || !$field(notnull)} {
		    if {[info exists field(default)]} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    } else {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }

	    fixedstring {
	        if {[info exists field(default)]} {
		    emit "        strncpy ($baseCopy.$fieldName, \"$field(default)\", $field(length));"
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    }
		} else {
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }

	    mac {
		if {[info exists field(default)]} {
		    emit "        $baseCopy.$fieldName = *ether_aton (\"$field(default)\");"
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    }
		} else {
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }

	    inet {
		if {[info exists field(default)]} {
		    emit "        inet_aton (\"$field(default)\", &$baseCopy.$fieldName);"
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    }
		} else {
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }

	    char {
	        if {[info exists field(default)]} {
		    emit "        $baseCopy.$fieldName = '[string index $field(default) 0]';"
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    }
		} else {
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }

	    tclobj {
	        emit "        $baseCopy.$fieldName = (Tcl_Obj *) NULL;"
		if {![info exists field(notnull)] || !$field(notnull)} {
		    emit "        $baseCopy._${fieldName}IsNull = 1;"
		}
	    }

	    default {
	        if {[info exists field(default)]} {
	            emit "        $baseCopy.$fieldName = $field(default);"
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 0;"
		    }
		} else {
		    if {![info exists field(notnull)] || !$field(notnull)} {
			emit "        $baseCopy._${fieldName}IsNull = 1;"
		    }
		}
	    }
	}
    }

    emit "    $rightCurly"
    emit ""
    emit "    *row = $baseCopy;"

    emit "$rightCurly"
    emit ""
}

#
# gen_delete_subr - gen code to delete (free) a row
#
proc gen_delete_subr {subr struct} {
    variable table
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    emit "void ${subr}(CTable *ctable, void *vRow, int indexCtl) {"
    emit "    struct $struct *row = vRow;"
    emit ""
    emit "    if (indexCtl == CTABLE_INDEX_NORMAL) {"
    emit "        ctable_RemoveFromAllIndexes (ctable, (void *)row);"
    emit "        ctable_DeleteHashEntry (ctable->keyTablePtr, (ctable_HashEntry *)row);"
    emit "    }"
    emit ""

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	switch $field(type) {
	    varstring {
	        emit "    if (row->$fieldName != (char *) NULL) ckfree ((void *)row->$fieldName);"
	    }
	}
    }
    emit "    ckfree ((void *)row);"

    emit "}"
    emit ""
}


set isNullSubrSource {
int ${table}_obj_is_null(Tcl_Obj *obj) {
    char     *nullValueString;
    int       nullValueLength;

    char     *objString;
    int       objStringLength;

     nullValueString = Tcl_GetStringFromObj (${table}_NullValueObj, &nullValueLength);
     objString = Tcl_GetStringFromObj (obj, &objStringLength);

    if (nullValueLength != objStringLength) {
        return 0;
    }

    if (nullValueLength == 0) {
        return 1;
    }

    if (*nullValueString != *objString) {
        return 0;
    }

    return (strncmp (nullValueString, objString, nullValueLength) == 0);
}
}

#
# gen_is_null_subr - gen code to determine if an object contains the null value
#
proc gen_obj_is_null_subr {} {
    variable table
    variable isNullSubrSource

    emit [string range [subst -nobackslashes -nocommands $isNullSubrSource] 1 end-1]
}

#
# sanity_check - prior to generating everything, make sure what we're being
#  asked to do is reasonable
#
proc sanity_check {} {
    variable fieldList
    variable table

    if {[llength $fieldList] == 0} {
        error "no fields defined in table \"$table\" -- at least one field must be defined in a table"
    }
}

#
# determine_how_many_linked_lists - count up the number of indexed
# nodes and any other stuff we want linked lists in the row for
#
# currently one defined for every row for a master linked list and one
# defined for each field that is defined indexed and not unique
# for use with skip lists to have indexes on fields of rows that have
# duplicate entries like, for instance, latitude and/or longitude.
#
proc determine_how_many_linked_lists_and_gen_field_index_table {} {
    variable nonBooleans
    variable fields
    variable fieldList
    variable booleans
    variable table
    variable leftCurly
    variable rightCurly

    set result "int ${table}_index_numbers\[\] = $leftCurly"
    set nLinkedLists 1
    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

        # if the "indexed" field doesn't exist or is 0, skip it
        if {![info exists field(indexed)] || !$field(indexed)} {
	    append result "\n    -1,"
            continue
        }
  
        # we're going to use linked lists even if it's not unique
if 0 {
        # if the "unique" field doesn't exist or isn't set to 0
        if {![info exists field(unique)] || $field(unique)} {
	    append result "\n    -1,"
            continue
        }
}
  
        # if we got here it's indexed and not unique,
        # i.e. field args include "indexed 1 unique 0"
        # generate them a list entry

	append result "\n[format "%6d" $nLinkedLists],"
  
        incr nLinkedLists
    }

    emit "[string range $result 0 end-1]\n$rightCurly;"

    return $nLinkedLists
}

#
# gen_struct - gen the table being defined's C structure
#
proc gen_struct {} {
    variable table
    variable booleans
    variable nonBooleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set nLinkedLists [determine_how_many_linked_lists_and_gen_field_index_table]
    set NLINKED_LISTS [string toupper $table]_NLINKED_LISTS
    emit "#define $NLINKED_LISTS $nLinkedLists"
    emit ""

    emit "struct $table $leftCurly"

    putfield "ctable_HashEntry" "hashEntry"
    putfield "ctable_LinkedListNode"  "_ll_nodes\[$NLINKED_LISTS\]"

    foreach fieldName $nonBooleans {
	upvar ::ctable::fields::$fieldName field

	switch $field(type) {
	    varstring {
		putfield char "*$field(name)"
		putfield int  "_$field(name)Length"
		putfield int  "_$field(name)AllocatedLength"
	    }

	    fixedstring {
		putfield char "$field(name)\[$field(length)]"
	    }

	    wide {
		putfield "Tcl_WideInt" $field(name)
	    }

	    mac {
		putfield "struct ether_addr" $field(name)
	    }

	    inet {
		putfield "struct in_addr" $field(name)
	    }

	    tclobj {
		putfield "struct Tcl_Obj" "*$field(name)"
	    }

	    key {
		# Do nothing, it's in the hashEntry
	    }

	    default {
		putfield $field(type) $field(name)
	    }
	}
    }

    foreach fieldName $booleans {
	putfield "unsigned int" "$fieldName:1"
    }

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	if {![info exists field(notnull)] || !$field(notnull)} {
	    putfield "unsigned int" _${fieldName}IsNull:1
	}
    }

    emit "$rightCurly;"
    emit ""
}

#
# emit_set_num_field - emit code to set a numeric field
#
proc emit_set_num_field {fieldName type} {
    variable numberSetSource
    variable table

    set typeText $type

    switch $type {
        short {
	    set newObjCmd Tcl_NewIntObj
	    set getObjCmd Tcl_GetIntFromObj
	    set typeText "int"
	}

        int {
	    set newObjCmd Tcl_NewIntObj
	    set getObjCmd Tcl_GetIntFromObj
	}

	long {
	    set newObjCmd Tcl_NewLongObj
	    set getObjCmd Tcl_GetLongFromObj

	}

	wide {
	    set type "Tcl_WideInt"
	    set newObjCmd Tcl_NewWideIntObj
	    set getObjCmd Tcl_GetWideIntFromObj
	    set typeText "Tcl_WideInt"
	}

	float {
	    set newObjCmd Tcl_NewDoubleObj
	    set getObjCmd Tcl_GetDoubleFromObj
	    set typeText "double"
	}

	double {
	    set newObjCmd Tcl_NewDoubleObj
	    set getObjCmd Tcl_GetDoubleFromObj
	}

	default {
	    error "unknown numeric field type: $type"
	}
    }

    set optname [field_to_enum $fieldName]

    emit [string range [subst $numberSetSource] 1 end-1]
}

#
# emit_set_standard_field - emit code to set a field that has a
# "set source" string to go with it and gets managed in a standard
#  way
#
proc emit_set_standard_field {fieldName setSourceVarName} {
    variable $setSourceVarName
    variable table

    set optname [field_to_enum $fieldName]
    emit [string range [subst [set $setSourceVarName]] 1 end-1]
}

#
# emit_set_varstring_field - emit code to set a varstring field
#
proc emit_set_varstring_field {table fieldName default defaultLength} {
    variable varstringSetSource

    set default [cquote $default]

    set optname [field_to_enum $fieldName]

    emit [string range [subst $varstringSetSource] 1 end-1]
}

#           
# emit_set_fixedstring_field - emit code to set a fixedstring field
#
proc emit_set_fixedstring_field {fieldName length} {
    variable fixedstringSetSource
    variable table
    variable nullCheckDuringSetSource
      
    set optname [field_to_enum $fieldName]

    emit [string range [subst $fixedstringSetSource] 1 end-1]
} 

set fieldIncrSource {
int
${table}_incr (Tcl_Interp *interp, CTable *ctable, Tcl_Obj *obj, struct $table *row, int field, int indexCtl) $leftCurly

    switch ((enum ${table}_fields) field) $leftCurly
}

set numberIncrNullCheckSource {
	if (row->_${fieldName}IsNull) {
	    // incr of a null field, default to 0
	    if ((indexCtl == CTABLE_INDEX_NORMAL) && ctable->skipLists[field] != NULL) {
		if (ctable_RemoveNullFromIndex (interp, ctable, row, field) == TCL_ERROR) {
		    return TCL_ERROR;
		}
	    }
	    row->_${fieldName}IsNull = 0;
	    row->$fieldName = incrAmount;

	    if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable->skipLists[field] != NULL)) {
		if (ctable_InsertIntoIndex (interp, ctable, row, field) == TCL_ERROR) {
		    return TCL_ERROR;
		}
	    }
	    break;
	}
}

#
# gen_number_incr_null_check_code - return code to check for null stuff
#  inside incr code, if the field doesn't prevent it by having notnull set,
#  in which case return nothing.
#
proc gen_number_incr_null_check_code {table fieldName} {
    variable numberIncrNullCheckSource
    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
        return [string range [subst -nobackslashes -nocommands $numberIncrNullCheckSource] 1 end-1]
    }
}

#
# gen_set_notnull_if_notnull - if the field has not been defined "not null",
#  return code to set that it isn't null
#
proc gen_set_notnull_if_notnull {table fieldName} {
    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    } else {
	return "row->_${fieldName}IsNull = 0;"
    }
}

#
# numberIncrSource - code we run subst over to generate a set of a standard
#  number such as an integer, long, double, and wide integer.  (We have to 
#  handle shorts and floats specially due to type coercion requirements.)
#
set numberIncrSource {
      case $optname: {
	int incrAmount;

	if (Tcl_GetIntFromObj (interp, obj, &incrAmount) == TCL_ERROR) {
	    Tcl_AppendResult (interp, " while converting $fieldName increment amount", (char *)NULL);
	    return TCL_ERROR;
	}
[gen_number_incr_null_check_code $table $fieldName]

	if ((indexCtl == CTABLE_INDEX_NORMAL) && ctable->skipLists\[field] != NULL) {
	    ctable_RemoveFromIndex (ctable, row, field);
	}

	row->$fieldName += incrAmount;
[gen_set_notnull_if_notnull $table $fieldName]
	if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable->skipLists\[field] != NULL)) {
	    if (ctable_InsertIntoIndex (interp, ctable, row, field) == TCL_ERROR) {
		return TCL_ERROR;
	    }
	}
	break;
      }
}

set illegalIncrSource {
      case $optname: {
	Tcl_ResetResult (interp);
	Tcl_AppendResult (interp, "can't incr non-numeric field '$fieldName'", (char *)NULL);
	    return TCL_ERROR;
	}
}

set incrFieldObjSource {
int
${table}_incr_fieldobj (Tcl_Interp *interp, CTable *ctable, Tcl_Obj *obj, struct $table *row, Tcl_Obj *fieldObj, int indexCtl)
{
    int field;

    if (Tcl_GetIndexFromObj (interp, fieldObj, ${table}_fields, "field", TCL_EXACT, &field) != TCL_OK) {
        return TCL_ERROR;
    }

    return ${table}_incr (interp, ctable, obj, row, field, indexCtl);
}
}

#
# emit_incr_num_field - emit code to incr a numeric field
#
proc emit_incr_num_field {fieldName} {
    variable numberIncrSource
    variable table

    set optname [field_to_enum $fieldName]

    emit [string range [subst $numberIncrSource] 1 end-1]
}

#
# emit_incr_illegal_field - we run this to generate code that will cause
#  an error on attempts to incr the field that's being processed -- for
#  when incr is not a reasonable thing
#
proc emit_incr_illegal_field {fieldName} {
    variable illegalIncrSource

    set optname [field_to_enum $fieldName]
    emit [string range [subst -nobackslashes -nocommands $illegalIncrSource] 1 end-1]
}

#
# gen_incrs - emit code to incr all of the incr'able fields of the table being 
# defined
#
proc gen_incrs {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	switch $field(type) {
	    int {
		emit_incr_num_field $fieldName
	    }

	    long {
		emit_incr_num_field $fieldName
	    }

	    wide {
		emit_incr_num_field $fieldName
	    }

	    double {
		emit_incr_num_field $fieldName
	    }

	    short {
		emit_incr_num_field $fieldName
	    }

	    float {
	        emit_incr_num_field $fieldName
	    }

	    default {
	        emit_incr_illegal_field $fieldName
	    }
	}
    }
}

#
# gen_incr_function - create a *_incr routine that takes a pointer to the
# tcl interp, an object, a pointer to a table row and a field number,
# and incrs that field in that row by the the value extracted from the obj
#
proc gen_incr_function {table} {
    variable fieldIncrSource
    variable incrFieldObjSource
    variable leftCurly
    variable rightCurly

    emit [string range [subst -nobackslashes -nocommands $fieldIncrSource] 1 end-1]

    gen_incrs

    emit "    $rightCurly"
    emit "    return TCL_OK;"
    emit "$rightCurly"

    emit [string range [subst -nobackslashes -nocommands $incrFieldObjSource] 1 end-1]
}

#
# gen_sets - emit code to set all of the fields of the table being defined
#
proc gen_sets {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	switch $field(type) {
	    key {
		emit_set_standard_field $fieldName keySetSource
	    }

	    int {
		emit_set_num_field $fieldName int
	    }

	    long {
		emit_set_num_field $fieldName long
	    }

	    wide {
		emit_set_num_field $fieldName wide
	    }

	    double {
		emit_set_num_field $fieldName double
	    }

	    short {
		emit_set_num_field $fieldName int
	    }

	    float {
		emit_set_num_field $fieldName float
	    }

	    fixedstring {
		emit_set_fixedstring_field $fieldName $field(length)
	    }

	    varstring {
	        if {[info exists field(default)]} {
		    set default $field(default)
		    set defaultLength [string length $field(default)]
		} else {
		    set default ""
		    set defaultLength 0
		}
		emit_set_varstring_field $table $fieldName $default $defaultLength
	    }

	    boolean {
		emit_set_standard_field $fieldName boolSetSource
	    }

	    char {
		emit_set_standard_field $fieldName charSetSource
	    }

	    inet {
	        emit_set_standard_field $fieldName inetSetSource
	    }

	    mac {
	        emit_set_standard_field $fieldName macSetSource
	    }

	    tclobj {
	        emit_set_standard_field $fieldName tclobjSetSource
	    }

	    default {
	        error "attempt to emit set field of unknown type $field(type)"
	    }
	}
    }
}

#
# setNullSource - code that gets substituted for nonnull fields for set_null
#
set setNullSource {
      case $optname: 
        if (row->_${myField}IsNull) {
	    break;
	}

	if ((indexCtl == CTABLE_INDEX_NORMAL) && (ctable->skipLists[field] != NULL)) {
	    ctable_RemoveFromIndex (ctable, row, field);
	}
        row->_${myField}IsNull = 1; 
	if ((indexCtl != CTABLE_INDEX_PRIVATE) && (ctable->skipLists[field] != NULL)) {
	    if (ctable_InsertNullIntoIndex (interp, ctable, row, field) == TCL_ERROR) {
		return TCL_ERROR;
	    }
	}
	break;
}

set setNullNotNullSource {
      case $optname: 
        Tcl_AppendResult (interp, "can't set non-null field \"${myField}\" to be null", (char *)NULL);
	return TCL_ERROR;
}

#
# gen_set_null_function - emit C routine to set a specific field to null
#  in a given table and row
#
proc gen_set_null_function {table} {
    variable fieldList
    variable leftCurly
    variable rightCurly
    variable setNullSource
    variable setNullNotNullSource

    emit "int"
    emit "${table}_set_null (Tcl_Interp *interp, CTable *ctable, struct $table *row, int field, int indexCtl) $leftCurly"

    emit "    switch ((enum ${table}_fields) field) $leftCurly"

    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

        set optname [field_to_enum $myField]

	if {[info exists field(notnull)] && $field(notnull)} {
	    emit [subst -nobackslashes -nocommands $setNullNotNullSource]
	} else {
	    emit [subst -nobackslashes -nocommands $setNullSource]
	}
    }

    emit "    $rightCurly"
    emit "    return TCL_OK;"
    emit "$rightCurly"
    emit ""
}

#
# put_metatable_source - emit the code to define the meta table (table-defining
# command)
#
proc put_metatable_source {table} {
    variable metaTableSource

    set Id {CTable template Id}

    emit [subst -nobackslashes -nocommands $metaTableSource]
}

#
# put_init_command_source - emit the code to initialize create within Tcl
# the command that will invoke the C command defined by 
# put_metatable_source
#
proc put_init_command_source {table} {
    variable extensionFragmentSource

    set Id {init extension Id}
    set NFIELDS [string toupper $table]_NFIELDS
    set NLINKED_LISTS [string toupper $table]_NLINKED_LISTS

    emit [subst -nobackslashes -nocommands $extensionFragmentSource]
}

#
# put_init_extension_source - emit the code to create the C functions that
# Tcl will expect to find when loading the shared library.
#
proc put_init_extension_source {extension extensionVersion} {
    variable initExtensionSource
    variable tables

    set Id {init extension Id}
    emit [subst -nobackslashes -nocommands $initExtensionSource]
}

#
# gen_set_function - create a *_set routine that takes a pointer to the
# tcl interp, an object, a pointer to a table row and a field number,
# and sets the value extracted from the obj into the field of the row
#
proc gen_set_function {table} {
    variable fieldObjSetSource
    variable fieldSetSource
    variable leftCurly
    variable rightCurly

    emit [string range [subst -nobackslashes -nocommands $fieldSetSource] 1 end-1]

    gen_sets

    emit "    $rightCurly"
    emit "    return TCL_OK;"
    emit "$rightCurly"

    emit [string range [subst -nobackslashes -nocommands $fieldObjSetSource] 1 end-1]

}

#
# gen_get_function - create a *_get routine that takes a pointer to the
#  tcl interp, an object pointer, a pointer to a table row and a field number,
#  and gets the value from the field of the row and store it into the
#  object.
#
#  Also create a *_get_fieldobj function that takes pointers to the same
#  tcl interpreter, object, and table row but takes an object containg
#  a string identifying the field, which is then looked up to identify
#  the field number and used in a call to the *_get function.
#
proc gen_get_function {table} {
    variable fieldObjGetSource
    variable lappendFieldAndNameObjSource
    variable lappendNonnullFieldAndNameObjSource
    variable arraySetFromFieldSource
    variable tabSepFunctionsSource
    variable fieldGetSource
    variable fieldGetStringSource
    variable leftCurly
    variable rightCurly

    emit [string range [subst -nobackslashes -nocommands $fieldGetSource] 1 end-1]
    gen_gets_cases
    emit "    $rightCurly"
    emit "    return TCL_OK;"
    emit "$rightCurly"

    emit [string range [subst -nobackslashes -nocommands $fieldObjGetSource] 1 end-1]

    emit [string range [subst -nobackslashes -nocommands $lappendFieldAndNameObjSource] 1 end-1]

    emit [string range [subst -nobackslashes -nocommands $lappendNonnullFieldAndNameObjSource] 1 end-1]

    emit [string range [subst -nobackslashes -nocommands $fieldGetStringSource] 1 end-1]
    gen_gets_string_cases
    emit "    $rightCurly"
    emit "    return TCL_OK;"
    emit "$rightCurly"

    emit [string range [subst -nobackslashes -nocommands $tabSepFunctionsSource] 1 end-1]

    emit [string range [subst -nobackslashes -nocommands $arraySetFromFieldSource] 1 end-1]
}

#
# gen_setup_routine - emit code to be run for this table type at shared 
#  libary load time
#
proc gen_setup_routine {table} {
    variable fieldList
    variable fields
    variable leftCurly
    variable rightCurly

    emit "void ${table}_setup (void) $leftCurly"

    # create and initialize all of the NameObj objects containing field
    # names as Tcl objects and increment their reference counts so 
    # (hopefully, heh) they'll never be deleted.
    #
    # also populate the *_NameObjList table
    # and the *_KeyObjList table
    # and the *_KeyIndex table
    #
    set position 0
    set keyPosition 0
    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

        if {[info exists field(key)] && $field(key)} {
	    emit "    ${table}_KeyIndex\[$keyPosition\] = $position;"
	    emit "    ${table}_KeyObjList\[$keyPosition\] ="
	    incr keyPosition
        }

	set nameObj [field_to_nameObj $table $fieldName]
        emit "    ${table}_NameObjList\[$position\] = $nameObj = Tcl_NewStringObj (\"$fieldName\", -1);"
	emit "    Tcl_IncrRefCount ($nameObj);"
	emit ""
	incr position
    }
    emit "    ${table}_KeyIndex\[$keyPosition\] = -1;"
    emit "    ${table}_KeyObjList\[$keyPosition\] ="
    emit "    ${table}_NameObjList\[$position\] = (Tcl_Obj *) NULL;"
    emit ""

    set emptyObj ${table}_DefaultEmptyStringObj
    emit "    $emptyObj = Tcl_NewObj ();"
    emit "    Tcl_IncrRefCount ($emptyObj);"
    emit ""

    #
    # create and initialize string objects for varstring defaults
    #
    emit "    // defaults for varstring objects, if any"
    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	if {$field(type) != "varstring"} continue
	if {![info exists field(default)]} continue

	set defObj ${table}_${fieldName}DefaultStringObj

	if {$field(default) != ""} {
	    emit "    $defObj = Tcl_NewStringObj (\"[cquote $field(default)]\", -1);"
	    emit "    Tcl_IncrRefCount ($defObj);"
	    emit ""
	}
    }

    emit "    // initialize the null string object to the default (empty) value"
    emit "    ${table}_NullValueObj = Tcl_NewObj ();"
    emit "    Tcl_IncrRefCount (${table}_NullValueObj);"

    emit "$rightCurly"
    emit ""
}

#
# gen_code - generate all of the code for the underlying methods for
#  managing a created table
#
proc gen_code {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly
    variable cmdBodySource

    #set pointer "${table}_ptr"
    set pointer p

    set Id {CTable template Id}

    set nFields [string toupper $table]_NFIELDS
    set nKeys [string toupper $table]_NKEYS

    set rowStruct $table

    gen_set_function $table

    gen_set_null_function $table

    gen_get_function $table

    gen_incr_function $table

    gen_field_compare_functions

    gen_sort_compare_function

    gen_search_compare_function

    gen_make_key_functions

    emit [subst -nobackslashes -nocommands $cmdBodySource]
}

#
# gen_new_obj - given a data type, pointer name and field name, return
#  the C code to generate a Tcl object containing that element from the
#  pointer pointing to the named field.
#
proc gen_new_obj {type fieldName} {
    variable table
    upvar ::ctable::fields::$fieldName field

    switch $type {
	key {
	    return "Tcl_NewStringObj (row->hashEntry.key, -1)"
	}

	short {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewIntObj (row->$fieldName)"
	    } else {
		return "Tcl_NewIntObj (row->$fieldName)"
	    }
	}

	int {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewIntObj (row->$fieldName)"
	    } else {
		return "Tcl_NewIntObj (row->$fieldName)"
	    }
	}

	long {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewLongObj (row->$fieldName)"
	    } else {
		return "Tcl_NewLongObj (row->$fieldName)"
	    }
	}

	wide {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewWideIntObj (row->$fieldName)"
	    } else {
		return "Tcl_NewWideIntObj (row->$fieldName)"
	    }
	}

	double {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewDoubleObj (row->$fieldName)"
	    } else {
		return "Tcl_NewDoubleObj (row->$fieldName)"
	    }
	}

	float {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewDoubleObj (row->$fieldName)"
	    } else {
		return "Tcl_NewDoubleObj (row->$fieldName)"
	    }
	}

	boolean {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewBooleanObj (row->$fieldName)"
	    } else {
		return "Tcl_NewBooleanObj (row->$fieldName)"
	    }
	}

	varstring {
	    # if there's no default for the var string, the null pointer 
	    # response is the null
	    if {![info exists field(default)]} {
	        set defObj ${table}_NullValueObj
	    } else {
		if {$field(default) == ""} {
		    set defObj ${table}_DefaultEmptyStringObj
		} else {
		    set defObj ${table}_${fieldName}DefaultStringObj
		}
	    }

	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : ((row->$fieldName == (char *) NULL) ? $defObj  : Tcl_NewStringObj (row->$fieldName, row->_${fieldName}Length))"
	    } else {
		return "(row->$fieldName == (char *) NULL) ? $defObj  : Tcl_NewStringObj (row->$fieldName, row->_${fieldName}Length)"
	    }
	}

	char {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewStringObj (&row->$fieldName, 1)"
	    } else {
		return "Tcl_NewStringObj (&row->$fieldName, 1)"
	    }
	}

	fixedstring {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewStringObj (row->$fieldName, $field(length))"
	    } else {
		return "Tcl_NewStringObj (row->$fieldName, $field(length))"
	    }
	}

	inet {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewStringObj (inet_ntoa (row->$fieldName), -1)"
	    } else {
		return "Tcl_NewStringObj (inet_ntoa (row->$fieldName), -1)"
	    }
	}

	mac {
	    if {![info exists field(notnull)] || !$field(notnull)} {
		return "row->_${fieldName}IsNull ? ${table}_NullValueObj : Tcl_NewStringObj (ether_ntoa (&row->$fieldName), -1)"
	    } else {
		return "Tcl_NewStringObj (ether_ntoa (&row->$fieldName), -1)"
	    }
	}

	tclobj {
	    return "((row->$fieldName == (Tcl_Obj *) NULL) ? Tcl_NewObj () : row->$fieldName)"
	}

	default {
	    error "no code to gen obj for type $type"
	}
    }
}

#
# gen_get_set_obj - given an object, a data type, pointer name and field name, 
#  return the C code to set a Tcl object to contain that element from the
#  pointer pointing to the named field.
#
# note: this is an inefficient way to get the value of varstrings,
# fixedstrings and chars, and can't even do tclobjs.  
#
# do what gen_get_string_cases does, or call its parent anyway *_get_string,
# to get string representations of those efficiently.
#
proc gen_get_set_obj {obj type fieldName} {
    variable fields
    variable table

    switch $type {
	short {
	    return "Tcl_SetIntObj ($obj, row->$fieldName)"
	}

	int {
	    return "Tcl_SetIntObj ($obj, row->$fieldName)"
	}

	long {
	    return "Tcl_SetLongObj ($obj, row->$fieldName)"
	}

	wide {
	    return "Tcl_SetWideIntObj ($obj, row->$fieldName)"
	}

	double {
	    return "Tcl_SetDoubleObj ($obj, row->$fieldName)"
	}

	float {
	    return "Tcl_SetDoubleObj ($obj, row->$fieldName)"
	}

	boolean {
	    return "Tcl_SetBooleanObj ($obj, row->$fieldName)"
	}

	varstring {
	    return "Tcl_SetStringObj ($obj, row->$fieldName, row->_${fieldName}Length)"
	}

	char {
	    return "Tcl_SetStringObj ($obj, &row->$fieldName, 1)"
	}

	fixedstring {
	    upvar ::ctable::fields::$fieldName field

	    return "Tcl_SetStringObj ($obj, row->$fieldName, $field(length))"
	}

	inet {
	    return "Tcl_SetStringObj ($obj, inet_ntoa (row->$fieldName), -1)"
	}

	mac {
	    return "Tcl_SetStringObj ($obj, ether_ntoa (&row->$fieldName), -1)"
	}

	tclobj {
	    error "can't set a string to a tclobj (field \"$fieldName\") -- you have to handle this outside of gen_get_set_obj"
	}

	default {
	    error "no code to gen obj for type $type"
	}
    }
}

#
# set_list_obj - generate C code to emit a Tcl obj containing the named
#  field into a list that's being cons'ed up
#
proc set_list_obj {position type fieldName} {
    emit "    listObjv\[$position] = [gen_new_obj $type $fieldName];"
}

#
# append_list_element - generate C code to append a list element to the
#  output object.  used by code that lets you get one or more named fields.
#
proc append_list_element {type fieldName} {
    return "Tcl_ListObjAppendElement (interp, Tcl_GetObjResult (interp), [gen_new_obj $type $fieldName])"
}

#
# gen_list - generate C code to emit an entire row into a Tcl list
#
proc gen_list {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set lengthDef [string toupper $table]_NFIELDS

    emit "Tcl_Obj *${table}_genlist (Tcl_Interp *interp, void *vPointer) $leftCurly"
    emit "    struct $table *row = vPointer;"

    emit "    Tcl_Obj *listObjv\[$lengthDef];"
    emit ""

    set position 0
    foreach fieldName $fieldList {
	if {[is_hidden $fieldName]} {
	    continue
	}

	upvar ::ctable::fields::$fieldName field

	set_list_obj $position $field(type) $fieldName

	incr position
    }

    emit "    return Tcl_NewListObj ($position, listObjv);"
    emit "$rightCurly"
    emit ""
}

#
# gen_keyvalue_list - generate C code to emit an entire row into a Tcl list in
#  "array set" format
#
proc gen_keyvalue_list {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set lengthDef [string toupper $table]_NFIELDS

    emit "Tcl_Obj *${table}_gen_keyvalue_list (Tcl_Interp *interp, void *vPointer) $leftCurly"
    emit "    struct $table *row = vPointer;"

    emit "    Tcl_Obj *listObjv\[$lengthDef * 2];"
    emit ""

    set position 0
    foreach fieldName $fieldList {
	if {[is_hidden $fieldName]} {
	    continue
	}

	upvar ::ctable::fields::$fieldName field

	emit "    listObjv\[$position] = [field_to_nameObj $table $fieldName];"
	incr position

	set_list_obj $position $field(type) $fieldName
	incr position

	emit ""
    }

    emit "    return Tcl_NewListObj ($position, listObjv);"
    emit "$rightCurly"
    emit ""
}

#
# gen_nonnull_keyvalue_list - generate C code to emit all of the nonnull
#   values in an entire row into a Tcl list in "array set" format
#
proc gen_nonnull_keyvalue_list {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set lengthDef [string toupper $table]_NFIELDS

    emit "Tcl_Obj *${table}_gen_nonnull_keyvalue_list (Tcl_Interp *interp, struct $table *row) $leftCurly"

    emit "    Tcl_Obj *listObjv\[$lengthDef * 2];"
    emit "    int position = 0;"
    emit "    Tcl_Obj *obj;"
    emit ""

    foreach fieldName $fieldList {
	if {[is_hidden $fieldName]} {
	    continue
	}

	upvar ::ctable::fields::$fieldName field

	if {[is_key $fieldName]} {
	    emit "    listObjv\[position++] = [field_to_nameObj $table $fieldName];"
	    emit "    listObjv\[position++] = [gen_new_obj $field(type) $fieldName];"
	} else {
	    emit "    obj = [gen_new_obj $field(type) $fieldName];"
	    emit "    if (obj != ${table}_NullValueObj) $leftCurly"
	    emit "        listObjv\[position++] = [field_to_nameObj $table $fieldName];"
	    emit "        listObjv\[position++] = obj;"
	    emit "    $rightCurly"
	}
    }

    emit "    return Tcl_NewListObj (position, listObjv);"
    emit "$rightCurly"
    emit ""
}

#
# key_names - Return the list of keyfield names
#
proc key_names {} {
    variable fields
    variable fieldList
    variable keyNames
    if ![info exists keyNames] {
        set keyNames {}
        foreach fieldName $fieldList {
	    upvar ::ctable::fields::$fieldName field

            if {[info exists field(key)] && $field(key)} {
	        lappend keyNames $fieldName
            }
        }
    }
    return $keyNames
}

#
# gen_make_key_functions - Generate C code to return the key fields as a list
#
proc gen_make_key_functions {} {
    gen_make_key_from_keylist
    gen_make_key_from_list
}

proc gen_make_key_from_keylist {} {
    variable table
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set keyNames [key_names]
    set lengthKey [string toupper $table]_NKEYS

    emit "Tcl_Obj *${table}_key_from_keylist (Tcl_Interp *interp, Tcl_Obj **objv, int objc) $leftCurly"

    if ![llength $keyNames] {
        emit "    return (Tcl_Obj *)NULL;"
    } else {
	emit "    int      i;"
        emit "    Tcl_Obj *listObjv\[$lengthKey];"
        emit ""

        emit "    for(i = 0; i < $lengthKey; i++)"
	emit "        listObjv\[i] = NULL;"
	emit ""

        emit "    for(i = 0; i < objc; i+=2) $leftCurly"
	set position 0
        foreach fieldName $keyNames {
	    emit "        if(strcmp(Tcl_GetString(objv\[i]), \"$fieldName\") == 0)"
	    emit "            listObjv\[$position] = objv\[i+1];"
	    incr position
        }
	emit "    $rightCurly"
	emit ""

        emit "    for(i = 0; i < $lengthKey; i++)"
	emit "        if(listObjv\[i] == NULL)"
	emit "            return NULL;"
	emit ""

        emit "    return Tcl_NewListObj ($lengthKey, listObjv);"
    }

    emit "$rightCurly"
    emit ""
}

proc gen_make_key_from_list {} {
    variable table
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    set keyNames [key_names]
    set lengthKey [string toupper $table]_NKEYS

    emit "Tcl_Obj *${table}_key_from_list (Tcl_Interp *interp, Tcl_Obj **objv, int objc) $leftCurly"

    if ![llength $keyNames] {
        emit "    return (Tcl_Obj *)NULL;"
    } else {
        emit "    Tcl_Obj *listObjv\[$lengthKey];"
        emit ""
        set maxIndex -1
        foreach fieldName $keyNames {
	    set index [lsearch $fieldList $fieldName]
	    if {$index > $maxIndex} {
		set maxIndex $index
	    }
        }
	emit "    if(objc <= $index) return NULL;"

	set position 0
        foreach fieldName $keyNames {
	    set index [lsearch $fieldList $fieldName]
	    emit "    listObjv\[$position] = objv\[$index];"
	    incr position
        }
	emit "    listObjv\[$lengthKey-1] = NULL;"
	emit ""

        emit "    return Tcl_NewListObj ($lengthKey, listObjv);"
    }

    emit "$rightCurly"
    emit ""
}

#
# gen_field_names - generate C code containing an array of pointers to strings
#  comprising the names of all of the fields in a row of the table being
#  defined.  Also generate an enumerated type of all of the field names
#  mapped to uppercase and prepended with FIELD_ for use with
#  Tcl_GetIndexFromObj in figuring out what fields are wanted
#
proc gen_field_names {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    emit "#define [string toupper $table]_NFIELDS [llength $fieldList]"
    emit ""

    emit "#define [string toupper $table]_NKEYS [llength [key_names]]"
    emit ""

    emit "static CONST char *${table}_fields\[] = $leftCurly"
    foreach fieldName $fieldList {
	emit "    \"$fieldName\","
    }
    emit "    (char *) NULL"
    emit "$rightCurly;\n"

    set fieldenum "enum ${table}_fields $leftCurly"
    foreach myField $fieldList {
	append fieldenum "\n    [field_to_enum $myField],"
    }
    set fieldenum "[string range $fieldenum 0 end-1]\n$rightCurly;\n"
    emit $fieldenum

    set typeList "enum ctable_types ${table}_types\[\] = $leftCurly"
    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	append typeList "\n    [ctable_type_to_enum $field(type)],"
    }
    emit "[string range $typeList 0 end-1]\n$rightCurly;\n"

    emit "// define per-field array for ${table} saying what fields need quoting"
    set needsQuoting "int ${table}_needs_quoting\[\] = $leftCurly"
    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	if {[info exists field(needsQuoting)] && $field(needsQuoting)} {
	    set quoting 1
	} else {
	    set quoting 0
	}
	append needsQuoting "\n    $quoting,"
    }
    emit "[string range $needsQuoting 0 end-1]\n$rightCurly;\n"

    emit "// define per-field array for ${table} saying what fields are unique"
    set unique "int ${table}_unique\[\] = $leftCurly"
    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	if {[info exists field(unique)] && $field(unique)} {
	    set uniqueVal 1
	} else {
	    set uniqueVal 0
	}
	append unique "\n    $uniqueVal,"
    }
    emit "[string range $unique 0 end-1]\n$rightCurly;\n"

    emit "// define objects that will be filled with the corresponding field names"
    foreach fieldName $fieldList {
        emit "Tcl_Obj *[field_to_nameObj $table $fieldName];"
    }
    emit ""

    emit "// define field property list keys and values to allow introspection"

    # do keys
    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	set propstring "char *[field_to_var $table $fieldName propkeys]\[] = $leftCurly"
    
	foreach fieldName [lsort [array names field]] {
	    append propstring "\"$fieldName\", "
	}
	emit "${propstring}(char *)NULL$rightCurly;"
    }
    emit ""

    set propstring "static char **${table}_propKeys\[] = $leftCurly"
    foreach fieldName $fieldList {
        append propstring "[field_to_var $table $fieldName propkeys],"
    }
    emit "[string range $propstring 0 end-1]$rightCurly;"
    emit ""
    # end of keys

    # do values, replica of keys, needs to be collapsed
    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	set propstring "char *[field_to_var $table $fieldName propvalues]\[] = $leftCurly"
    
	foreach fieldName [lsort [array names field]] {
	    append propstring "\"$field($fieldName)\", "
	}
	emit "${propstring}(char *)NULL$rightCurly;"
    }
    emit ""

    set propstring "static char **${table}_propValues\[] = $leftCurly"
    foreach fieldName $fieldList {
        append propstring "[field_to_var $table $fieldName propvalues],"
    }
    emit "[string range $propstring 0 end-1]$rightCurly;"
    emit ""
    # end of values

    emit "Tcl_Obj *${table}_NameObjList\[[string toupper $table]_NFIELDS + 1\];"
    emit ""

    emit "int      ${table}_KeyIndex\[[string toupper $table]_NKEYS + 1\];"
    emit "Tcl_Obj *${table}_KeyObjList\[[string toupper $table]_NKEYS + 1\];"
    emit ""

    emit "Tcl_Obj *${table}_DefaultEmptyStringObj;"
    emit ""

    emit "// define the null value object"
    emit "Tcl_Obj *${table}_NullValueObj;"
    emit ""

    emit "// define default objects for varstring fields, if any"
    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	if {$field(type) == "varstring" && [info exists field(default)]} {
	    if {$field(default) != ""} {
		emit "Tcl_Obj *${table}_${myField}DefaultStringObj;"
	    }
	}
    }
    emit ""
}

#
# gen_gets_cases - generate case statements for each field, each case fetches
#  field from row and returns a new Tcl_Obj set with that field's value
#
proc gen_gets_cases {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	emit "      case [field_to_enum $myField]:"
	emit "        return [gen_new_obj $field(type) $myField];"
	emit ""
    }
}

#
# gen_gets_string_cases - generate case statements for each field, each case
#  generates a return of a char * to a string representing that field's
#  value and sets a passed-in int * to the length returned.
#
proc gen_gets_string_cases {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    foreach myField $fieldList {
	upvar ::ctable::fields::$myField field

	emit "      case [field_to_enum $myField]:"

	if {![info exists field(notnull)] || !$field(notnull)} {
	    emit "        if (row->_${myField}IsNull) $leftCurly"
	    emit "            return Tcl_GetStringFromObj (${table}_NullValueObj, lengthPtr);"
	    emit "        $rightCurly"
	}

	switch $field(type) {
	  "key" {
	    emit "        *lengthPtr = strlen(row->hashEntry.key);"
	    emit "        return row->hashEntry.key;"
	  }

	  "varstring" {
	    emit "        if (row->${myField} == NULL) $leftCurly"

	    if {![info exists field(default)] || $field(default) == ""} {
	        set source ${table}_DefaultEmptyStringObj
	    } else {
	        set source ${table}_${myField}DefaultStringObj
	    }
	    emit "            return Tcl_GetStringFromObj ($source, lengthPtr);"
	    emit "        $rightCurly"
	    emit "        *lengthPtr = row->_${myField}Length;"
	    emit "        return row->$myField;"
	  }

	  "fixedstring" {
	      emit "        *lengthPtr = $field(length);"
	      emit "        return row->$myField;"
	  }

	  "char" {
	      emit "        *lengthPtr = 1;"
	      emit "        return &row->$myField;"
	  }

	  "tclobj" {
	    emit "        if (row->$myField == NULL) $leftCurly"
	    emit "            return Tcl_GetStringFromObj (${table}_DefaultEmptyStringObj, lengthPtr);"
	    emit "        $rightCurly"
	    emit "        return Tcl_GetStringFromObj (row->$myField, lengthPtr);"
	  }

	  default {
	      emit "        [gen_get_set_obj utilityObj $field(type) $myField];"
	      emit "        return Tcl_GetStringFromObj (utilityObj, lengthPtr);"
	  }
	}
	emit ""
    }
}

#
# gen_preamble - generate stuff that goes at the head of the C file
#  we're generating
#
proc gen_preamble {} {
    variable withPgtcl
    variable preambleCannedSource

    emit "/* autogenerated by ctable table generator [clock format [clock seconds]] */"
    emit "/* DO NOT EDIT */"
    emit ""
    if {$withPgtcl} {
        emit "#define WITH_PGTCL"
        emit ""
    }

    emit $preambleCannedSource

}

#####
#
# Field Compare Function Generation
#
#####

#
# fieldCompareNullCheckSource - this checks for nulls when comparing a field
#
set fieldCompareNullCheckSource {
    // nulls sort high
    if (row1->_${fieldName}IsNull) {
	if (row2->_${fieldName}IsNull) {
	    return 0;
	}
	return 1;
    } else if (row2->_${fieldName}IsNull) {
	return -1;
    }
}

#
# gen_field_compare_null_check_source - return code to be emitted into a field
#  compare, nothing if the field is not null else code to check for null
#
proc gen_field_compare_null_check_source {table fieldName} {
    variable fieldCompareNullCheckSource
    upvar ::ctable::fields::$fieldName field

    if {[info exists field(notnull)] && $field(notnull)} {
        return ""
    }

    return [string range [subst -nobackslashes -nocommands $fieldCompareNullCheckSource] 1 end-1]
}

#
# fieldCompareHeaderSource - code for defining a field compare function
#
set fieldCompareHeaderSource {
// field compare function for field '$fieldName' of the '$table' table...
int ${table}_field_${fieldName}_compare(const ctable_BaseRow *vPointer1, const ctable_BaseRow *vPointer2) $leftCurly
    struct ${table} *row1, *row2;

    row1 = (struct $table *) vPointer1;
    row2 = (struct $table *) vPointer2;
[gen_field_compare_null_check_source $table $fieldName]
}

set fieldCompareTrailerSource {
$rightCurly
}

#
# keyCompareSource - code for defining a key compare function
#
set keyCompareSource {
// field compare function for key of the '$table' table...
int ${table}_key_compare(const ctable_BaseRow *vPointer1, const ctable_BaseRow *vPointer2) $leftCurly
    struct ${table} *row1, *row2;

    row1 = (struct $table *) vPointer1;
    row2 = (struct $table *) vPointer2;
    if (*row1->hashEntry.key != *row2->hashEntry.key) {
        if (*row1->hashEntry.key < *row2->hashEntry.key) {
	    return -1;
	} else {
	    return 1;
	}
    }
    return strcmp(row1->hashEntry.key, row2->hashEntry.key);
$rightCurly
}

#
# boolFieldCompSource - code we run subst over to generate a compare of a 
# boolean (bit) for use in a field comparison routine.
#
set boolFieldCompSource {
    if (row1->$fieldName && !row2->$fieldName) {
	return -1;
    }

    if (!row1->$fieldName && row2->$fieldName) {
	return 1;
    }

    return 0;
}

#
# numberFieldSource - code we run subst over to generate a compare of a standard
#  number such as an integer, long, double, and wide integer for use in field
#  compares.
#
set numberFieldCompSource {
    if (row1->$fieldName < row2->$fieldName) {
        return -1;
    }

    if (row1->$fieldName > row2->$fieldName) {
	return 1;
    }

    return 0;
}

#
# varstringFieldCompSource - code we run subst over to generate a compare of 
# a string for use in searching, sorting, etc.
#
set varstringFieldCompSource {
    if (*row1->$fieldName != *row2->$fieldName) {
        if (*row1->$fieldName < *row2->$fieldName) {
	    return -1;
	} else {
	    return 1;
	}
    }
    return strcmp (row1->$fieldName, row2->$fieldName);
}

#
# fixedstringFieldCompSource - code we run subst over to generate a comapre of a 
# fixed-length string for use in a searching, sorting, etc.
#
set fixedstringFieldCompSource {
    if (*row1->$fieldName != *row2->$fieldName) {
        if (*row1->$fieldName < *row2->$fieldName) {
	    return -1;
	} else {
	    return 1;
	}
    }
    return strncmp (row1->$fieldName, row2->$fieldName, $length);
}

#
# binaryDataFieldCompSource - code we run subst over to generate a comapre of a 
# inline binary arrays (inets and mac addrs) for use in searching and sorting.
#
set binaryDataFieldCompSource {
    return memcmp (&row1->$fieldName, &row2->$fieldName, $length);
}

#
# tclobjFieldCompSource - code we run subst over to generate a compare of 
# a tclobj for use in searching and sorting.
#
set tclobjFieldCompSource {
    return strcmp (Tcl_GetString (row1->$fieldName), Tcl_GetString (row2->$fieldName));
}

#
# gen_field_comp - emit code to compare a field for a field comparison routine
#
proc gen_field_comp {fieldName} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    variable numberFieldCompSource
    variable fixedstringFieldCompSource
    variable binaryDataFieldCompSource
    variable varstringFieldCompSource
    variable boolFieldCompSource
    variable keyCompSource
    variable tclobjFieldCompSource

    upvar ::ctable::fields::$fieldName field

    switch $field(type) {
	key {
	    emit [string range [subst -nobackslashes -nocommands $keyCompSource] 1 end-1]
	}

	int {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	long {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	wide {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	double {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	short {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	float {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	char {
	    emit [string range [subst -nobackslashes -nocommands $numberFieldCompSource] 1 end-1]
	}

	fixedstring {
	    set length $field(length)
	    emit [string range [subst -nobackslashes -nocommands $fixedstringFieldCompSource] 1 end-1]
	}

	varstring {
	    emit [string range [subst -nobackslashes -nocommands $varstringFieldCompSource] 1 end-1]
	}

	boolean {
	    emit [string range [subst -nobackslashes -nocommands $boolFieldCompSource] 1 end-1]
	}

	inet {
	    set length "sizeof(struct in_addr)"
	    emit [string range [subst -nobackslashes -nocommands $binaryDataFieldCompSource] 1 end-1]
	}

	mac {
	    set length "sizeof(struct ether_addr)"
	    emit [string range [subst -nobackslashes -nocommands $binaryDataFieldCompSource] 1 end-1]
	}

	tclobj {
	    emit [string range [subst -nobackslashes -nocommands $tclobjFieldCompSource] 1 end-1]
	}

	default {
	    error "attempt to emit sort compare source for field of unknown type $field(type)"
	}
    }
}
#
# gen_field_compare_functions - generate functions for each field that will
# compare that field from two row pointers and return -1, 0, or 1.
#
proc gen_field_compare_functions {} {
    variable table
    variable leftCurly
    variable rightCurly
    variable fieldCompareHeaderSource
    variable fieldCompareTrailerSource
    variable keyCompareSource
    variable fieldList

    # generate all of the field compare functions
    foreach fieldName $fieldList {
	if [is_key $fieldName] {
	    emit [subst -nobackslashes $keyCompareSource]
	    continue
	}
	emit [string range [subst -nobackslashes $fieldCompareHeaderSource] 1 end-1]
	gen_field_comp $fieldName
	emit [string range [subst -nobackslashes -nocommands $fieldCompareTrailerSource] 1 end-1]
    }

    # generate an array of pointers to field compare functions for this type
    emit "// array of table's field compare routines indexed by field number"
    emit "fieldCompareFunction_t ${table}_compare_functions\[] = $leftCurly"
    set typeList ""
    foreach fieldName $fieldList {
	if [is_key $fieldName] {
	    append typeList "\n    ${table}_key_compare,"
	} else {
	    append typeList "\n    ${table}_field_${fieldName}_compare,"
	}
    }
    emit "[string range $typeList 0 end-1]\n$rightCurly;\n"
}

#####
#
# Sort Comparison Function Generation
#
#####

set sortCompareHeaderSource {

int ${table}_sort_compare(void *clientData, const void *vRow1, const void *vRow2) $leftCurly
    CTableSort *sortControl = (CTableSort *)clientData;
    const struct $table *row1 = (*(void **)vRow1);
    const struct $table *row2 = (*(void **)vRow2);
    int              i;
    int              direction;
    int              result = 0;

// printf ("sort comp he1 %lx, he2 %lx, p1 %lx, p2 %lx\n", (long unsigned int)hashEntryPtr1, (long unsigned int)hashEntryPtr2, (long unsigned int)row1, (long unsigned int)row2);

    for (i = 0; i < sortControl->nFields; i++) $leftCurly
        direction = sortControl->directions[i];
        switch (sortControl->fields[i]) $leftCurly 
}

set sortCompareTrailerSource {
        $rightCurly // end of switch

	// if they're not equal, we're done.  if they are, we may need to
	// compare a subordinate sort field (if there is one)
	if (result != 0) {
	    break;
	}

	// if this fields is sort-descending, flip the sense of the result
	if (!sortControl->directions[i]) {
	    result = -result;
	}
    $rightCurly // end of for loop on sort fields
    return result;
$rightCurly
}

#
# gen_sort_compare_function - generate a function that will compare fields
# in two ctable structures for use by qsort
#
proc gen_sort_compare_function {} {
    variable table
    variable leftCurly
    variable rightCurly
    variable sortCompareHeaderSource
    variable sortCompareTrailerSource

    emit [string range [subst -nobackslashes -nocommands $sortCompareHeaderSource] 1 end-1]

    gen_sort_comp

    emit [string range [subst -nobackslashes -nocommands $sortCompareTrailerSource] 1 end-1]
}

#
# gen_sort_comp - emit code to compare fields for sorting
#
proc gen_sort_comp {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    variable numberSortSource
    variable fixedstringSortSource
    variable binaryDataSortSource
    variable varstringSortSource
    variable boolSortSource
    variable keySortSource
    variable tclobjSortSource

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	set fieldEnum [field_to_enum $fieldName]

	switch $field(type) {
	    key {
		emit [string range [subst -nobackslashes $keySortSource] 1 end-1]
	    }

	    int {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    long {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    wide {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    double {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    short {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    float {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    char {
		emit [string range [subst -nobackslashes $numberSortSource] 1 end-1]
	    }

	    fixedstring {
	        set length $field(length)
		emit [string range [subst -nobackslashes $fixedstringSortSource] 1 end-1]
	    }

	    varstring {
		emit [string range [subst -nobackslashes $varstringSortSource] 1 end-1]
	    }

	    boolean {
		emit [string range [subst -nobackslashes $boolSortSource] 1 end-1]
	    }

	    inet {
	        set length "sizeof(struct in_addr)"
		emit [string range [subst -nobackslashes $binaryDataSortSource] 1 end-1]
	    }

	    mac {
		set length "sizeof(struct ether_addr)"
		emit [string range [subst -nobackslashes $binaryDataSortSource] 1 end-1]
	    }

	    tclobj {
		emit [string range [subst -nobackslashes $tclobjSortSource] 1 end-1]
	    }

	    default {
	        error "attempt to emit sort compare source for field $fieldName of unknown type $field(type)"
	    }
	}
    }
}

#####
#
# Search Comparison Function Generation
#
#####

set searchCompareHeaderSource {

// compare a row to a block of search components and see if it matches
int ${table}_search_compare(Tcl_Interp *interp, CTableSearch *searchControl, void *vPointer, int firstComponent) $leftCurly
    struct $table *row = (struct $table *)vPointer;
    struct $table *row1;

    int                                 i;
    int                                 exclude = 0;
    int                                 compType;
    CTableSearchComponent              *component;

    for (i = firstComponent; i < searchControl->nComponents; i++) $leftCurly
      component = &searchControl->components[i];

      row1 = (struct $table *)component->row1;
      compType = component->comparisonType;

      switch (compType) {
	case CTABLE_COMP_LT:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) < 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

	case CTABLE_COMP_LE:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) <= 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

	case CTABLE_COMP_EQ:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) == 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

	case CTABLE_COMP_NE:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) != 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

	case CTABLE_COMP_GE:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) >= 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

	case CTABLE_COMP_GT:
	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) > 0) {
	      continue;
	  }
	  return TCL_CONTINUE;

        case CTABLE_COMP_RANGE: {
	  struct $table *row2;

	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row1) < 0) {
	      return TCL_CONTINUE;
	  }

	  row2 = (struct $table *)component->row2;

	  if (component->compareFunction ((ctable_BaseRow *)row, (ctable_BaseRow *)row2) >= 0) {
	      return TCL_CONTINUE;
	  }
	  continue;
	}
      }

      switch (component->fieldID) $leftCurly
}

set searchCompareTrailerSource {
       $rightCurly // end of switch on field ID

        // if exclude got set, we're done.
	if (exclude) {
	    return TCL_CONTINUE;
	}
    $rightCurly // end of for loop on search fields
    return TCL_OK;
$rightCurly
}

#
# gen_search_compare_function - generate a function that see if a row in
# a ctable matches the search criteria
#
proc gen_search_compare_function {} {
    variable table
    variable leftCurly
    variable rightCurly
    variable searchCompareHeaderSource
    variable searchCompareTrailerSource

    emit [string range [subst -nobackslashes -nocommands $searchCompareHeaderSource] 1 end-1]

    gen_search_comp

    emit [string range [subst -nobackslashes -nocommands $searchCompareTrailerSource] 1 end-1]
}

#
# gen_search_comp - emit code to compare fields for searching
#
proc gen_search_comp {} {
    variable table
    variable booleans
    variable fields
    variable fieldList
    variable leftCurly
    variable rightCurly

    variable numberCompSource
    variable fixedstringCompSource
    variable binaryDataCompSource
    variable varstringCompSource
    variable boolCompSource
    variable keyCompSource
    variable tclobjCompSource

    variable standardCompSwitchSource
    variable standardCompNullCheckSource

    set value sandbag

    foreach fieldName $fieldList {
	upvar ::ctable::fields::$fieldName field

	set fieldEnum [field_to_enum $fieldName]
	set type $field(type)
        set typeText $field(type)

	switch $type {
	    int {
		set getObjCmd Tcl_GetIntFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    long {
		set getObjCmd Tcl_GetLongFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    wide {
		set getObjCmd Tcl_GetWideIntFromObj
		set typeText "Tcl_WideInt"
		set type "Tcl_WideInt"
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    double {
		set getObjCmd Tcl_GetDoubleFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    short {
		set typeText "int"
		set getObjCmd Tcl_GetIntFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    float {
		set typeText "double"
		set getObjCmd Tcl_GetDoubleFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    char {
		set typeText "int"
		set getObjCmd Tcl_GetIntFromObj
		emit [string range [subst -nobackslashes $numberCompSource] 1 end-1]
	    }

	    fixedstring {
		set getObjCmd Tcl_GetString
	        set length $field(length)
		emit [string range [subst -nobackslashes $fixedstringCompSource] 1 end-1]
	    }

	    varstring {
		set getObjCmd Tcl_GetString
		emit [string range [subst -nobackslashes $varstringCompSource] 1 end-1]
	    }

	    boolean {
		set getObjCmd Tcl_GetBooleanFromObj
		emit [string range [subst -nobackslashes $boolCompSource] 1 end-1]
	    }

	    inet {
		set getObjCmd Tcl_GetStringFromObj
	        set length "sizeof(struct in_addr)"
		emit [string range [subst -nobackslashes $binaryDataCompSource] 1 end-1]
	    }

	    mac {
		set getObjCmd Tcl_GetStringFromObj
		set length "sizeof(struct ether_addr)"
		emit [string range [subst -nobackslashes $binaryDataCompSource] 1 end-1]
	    }

	    tclobj {
		set getObjCmd Tcl_GetStringFromObj
		emit [string range [subst -nobackslashes $tclobjCompSource] 1 end-1]
	    }

	    key {
		set getObjCmd Tcl_GetString
	        set length "strlen(row->hashEntry.key)"
		emit [string range [subst -nobackslashes $keyCompSource] 1 end-1]
	    }

	    default {
	        error "attempt to emit search compare source for field of unknown type $field(type)"
	    }
	}
    }
}

#####
#
# Invoking the Compiler
#
#####

proc myexec {command} {
    variable showCompilerCommands

    if {$showCompilerCommands} {
	puts $command
    }

    eval exec $command
}

#
# compile - compile and link the shared library
#
proc compile {fileFragName version} {
    global tcl_platform
    variable buildPath
    variable pgtcl_ver
    variable genCompilerDebug
    variable memDebug
    variable targetDir
    variable pgTargetDir

    set buildFragName $buildPath/$fileFragName-$version
    set sourceFile $buildFragName.c
    set objFile $buildFragName.o

    # add -pg for profiling with gprof

    switch $tcl_platform(os) {
	"FreeBSD" {
	    if {$genCompilerDebug} {
		set optflag "-O0"
		set dbgflag "-g"
		set stub "-ltclstub8.4g"
		set lib "-ltcl84g"
	    } else {
		set optflag "-O3"
		set dbgflag ""
		set stub "-ltclstub84"
		set lib "-ltcl84"
	    }

	    # put -DTCL_MEM_DEBUG in there if you're building with
	    # memory debugging (see Tcl docs)
	    if {$memDebug} {
		set memDebugString "-DTCL_MEM_DEBUG=1"
	    } else {
		set memDebugString ""
	    }

	    myexec "gcc -pipe $optflag $dbgflag -fPIC -I$targetDir/include -I$targetDir/include/tcl8.4 -I$pgTargetDir/include -I$buildPath -Wall -Wno-implicit-int -fno-common -DUSE_TCL_STUBS=1 $memDebugString -c $sourceFile -o $objFile"

	    myexec "ld -Bshareable $dbgflag -x -o $buildPath/lib${fileFragName}.so $objFile -R$pgTargetDir/lib/pgtcl$pgtcl_ver -L$pgTargetDir/lib/pgtcl$pgtcl_ver -lpgtcl$pgtcl_ver -L$pgTargetDir/lib -lpq -L$targetDir/lib $stub"
	    #myexec "ld -Bshareable $dbgflag -x -o $buildPath/lib${fileFragName}.so $objFile -L$targetDir/lib $stub"
	}

# -finstrument-functions / -lSaturn

	"Darwin" {
	    if {$genCompilerDebug} {
		set dbgflag "-g"
		#set optflag "-O2"
		set optflag ""
		set stub "-ltclstub8.4g"
		set lib "-ltcl8.4g"
	    } else {
		set dbgflag ""
		set optflag "-O3"
		set stub "-ltclstub8.4"
		set lib "-ltcl8.4"
	    }

	    myexec "gcc -pipe -DCTABLE_NO_SYS_LIMITS $dbgflag $optflag -fPIC -Wall -Wno-implicit-int -fno-common -I$targetDir/include -I$buildPath -DUSE_TCL_STUBS=1 -c $sourceFile -o $objFile"

	    myexec "gcc -pipe $dbgflag $optflag -fPIC -dynamiclib  -Wall -Wno-implicit-int -fno-common -headerpad_max_install_names -Wl,-search_paths_first -Wl,-single_module -o $buildPath/${fileFragName}${version}.dylib $objFile -L/System/Library/Frameworks/Tcl.framework/Versions/8.4 $stub"

	    #exec gcc -pipe $optflag -fPIC -Wall -Wno-implicit-int -fno-common -I/sc/include -I$buildPath -DUSE_TCL_STUBS=1 -c $sourceFile -o $objFile

	    #exec gcc -pipe $optflag -fPIC -dynamiclib  -Wall -Wno-implicit-int -fno-common  -Wl,-single_module -o $buildPath/${fileFragName}${version}.dylib $objFile -L/sc/lib -lpq -L/sc/lib/pgtcl$pgtcl_ver -lpgtcl$pgtcl_ver $stub
	    #exec gcc -pipe $optflag -fPIC -dynamiclib  -Wall -Wno-implicit-int -fno-common -headerpad_max_install_names -Wl,-search_paths_first -Wl,-single_module -o $buildPath/${fileFragName}${version}.dylib $objFile -L/sc/lib -lpq -L/sc/lib/pgtcl$pgtcl_ver -lpgtcl -L/sc/lib $stub
	    #exec gcc -pipe $optflag -fPIC -dynamiclib  -Wall -Wno-implicit-int -fno-common -headerpad_max_install_names -Wl,-search_paths_first -Wl,-single_module -o $buildPath/${fileFragName}${version}.dylib $objFile -L/sc/lib -lpgtcl -L/sc/lib $stub
	    #exec gcc -pipe $optflag -fPIC -dynamiclib  -Wall -Wno-implicit-int -fno-common -headerpad_max_install_names -Wl,-search_paths_first -Wl,-single_module -o $buildPath/${fileFragName}${version}.dylib $objFile -L/sc/lib $stub


	    # -L/sc/lib -lpq -L/sc/lib/pgtcl$pgtcl_ver -lpgtcl$pgtcl_ver
	    # took $lib off the end?
	}

	default {
	    error "unknown OS $tcl_platform(os)"
	}
    }

    pkg_mkIndex $buildPath
}

proc EndExtension {} {
    variable tables
    variable extension
    variable extensionVersion
    variable rightCurly
    variable ofp

    put_init_extension_source [string totitle $extension] $extensionVersion

    foreach name $tables {
	put_init_command_source $name
    }

    emit "    return TCL_OK;"
    emit $rightCurly

    close $ofp

    compile $extension $::ctable::extensionVersion
}

#
# extension_already_built - see if the extension already exists unchanged
#  from what's being asked for
#
proc extension_already_built {name version code} {
    variable buildPath
    variable cvsID
    variable genCompilerDebug
    variable srcDir

    set ctFile $buildPath/$name-$version.ct

    # if open of the stash file fails, it ain't built
    if {[catch {open $ctFile} fp] == 1} {
        #puts ".ct file not there, build required"
        return 0
    }

    # read the first line for the prior CVS ID, if failed, report not built
    if {[gets $fp controlLine] < 0} {
        #puts "first line read of .ct file failed, build required"
        close $fp
	return 0
    }

    # this needs to match whavtever save_extension_code writes
    set expectControlLine [list $cvsID $genCompilerDebug [file mtime $srcDir]]

    # See if this file's control line matches the line in the .ct file.
    # If not, rebuild not built.
    if {$controlLine != $expectControlLine} {
        #puts "control line does not match, build required"
	return 0
    }

    set priorCode [read -nonewline $fp]
    close $fp

    # if the prior code and current code aren't identical, report not built
    if {$priorCode != $code} {
        #puts "extension code changed, build required"
	return 0
    }

    #puts "prior code and generator cvs match, build not required"
    return 1
}

#
# save_extension_code - after a successful build, cache the extension
#  definition so extension_already_built can see if it's necessary to
#  generate, compile and link the shared library next time we're run
#
proc save_extension_code {name version code} {
    variable buildPath
    variable cvsID
    variable leftCurly
    variable rightCurly
    variable genCompilerDebug
    variable srcDir

    set ctFile $buildPath/$name-$version.ct

    set fp [open $ctFile w]

    # this needs to match whavtever extension_ready_built expects
    puts $fp [list $cvsID $genCompilerDebug [file mtime $srcDir]]
    puts $fp $code
    close $fp
}

#
# install_ch_files - install .h in the target dir if something like it
#  isn't there already
#
proc install_ch_files {targetDir} {
    variable srcDir

    set copyFiles {
	ctable.h ctable_search.c ctable_lists.c ctable_batch.c
	boyer_moore.c jsw_rand.c jsw_rand.h jsw_slib.c jsw_slib.h
	speedtables.h speedtableHash.c
    }

    foreach file $copyFiles {
	if {[file exists $srcDir/$file]} {
            file copy -force $srcDir/$file $targetDir
	} elseif {[file exists $srcDir/skiplists/$file]} {
            file copy -force $srcDir/skiplists/$file $targetDir
	} elseif {[file exists $srcDir/hash/$file]} {
            file copy -force $srcDir/hash/$file $targetDir
	} else {
	    return -code error "Can't find $file in $srcDir"
	}
    }
}

#
# get_error_info - to keep tracebacks from containing lots of internals
#  of ctable stuff, we scarf errorInfo into ctableErrorInfo if we get
#  an error interpreting a CExtension/CTable definition.  This allows
#  one to get the error info if debugging is required, etc.
#
proc get_error_info {} {
    variable ctableErrorInfo

    return $ctableErrorInfo
}

}

#
# CExtension - define a C extension
#
proc CExtension {name version code} {
    global tcl_platform errorInfo errorCode

    # clear the error info placeholder
    set ctableErrorInfo ""

    if {![info exists ::ctable::buildPath]} {
        CTableBuildPath build
    }

    file mkdir $::ctable::buildPath

    ::ctable::install_ch_files $::ctable::buildPath

    if {[::ctable::extension_already_built $name $version $code]} {
        #puts stdout "extension $name $version unchanged"
	return
    }

    set ::ctable::ofp [open $::ctable::buildPath/$name-$version.c w]

    ::ctable::gen_preamble
    ::ctable::gen_ctable_type_stuff

    ::ctable::emit "#include \"ctable_search.c\""

    ::ctable::emit "static char *sourceCode = \"[::ctable::cquote "CExtension $name $version { $code }"]\";"
    ::ctable::emit ""

    ::ctable::emit "static char *ctablePackageVersion = \"$::ctable::ctablePackageVersion\";"

    set ::ctable::extension $name
    set ::ctable::extensionVersion $version
    set ::ctable::tables ""

    foreach var [info vars ::ctable::fields::*] {
        unset -nocomplain $var
    }

    if {[catch {namespace eval ::ctable $code} result] == 1} {
        set ::ctable::ctableErrorInfo $errorInfo

	if $::ctable::errorDebug {
	    return -code error -errorcode $errorCode -errorinfo $errorInfo
	} else {
            return -code error -errorcode $errorCode "$result\n(run ::ctable::get_error_info to see ctable's internal errorInfo)"
	}
    }

    ::ctable::EndExtension

    ::ctable::save_extension_code $name $version $code
}

#
# CTable - define a C meta table
#
proc CTable {name data} {
    ::ctable::table $name
    lappend ::ctable::tables $name

    #we can't do it this way, read_tabsep and stuff think it's standard
    # no interface to _dirty yet
    #::ctable::boolean _dirty

    namespace eval ::ctable $data

    ::ctable::sanity_check

    # Create a key field if there isn't already one
    ::ctable::key _key

    ::ctable::gen_struct

    ::ctable::gen_field_names

    ::ctable::gen_setup_routine $name

    ::ctable::gen_defaults_subr ${name}_init $name

    ::ctable::gen_delete_subr ${name}_delete $name

    ::ctable::gen_obj_is_null_subr

    ::ctable::gen_list

    ::ctable::gen_keyvalue_list

    ::ctable::gen_nonnull_keyvalue_list

    ::ctable::gen_code

    ::ctable::put_metatable_source $name

}

#
# CTableBuildPath - set the path for where we're building CTable stuff
#
proc CTableBuildPath {dir} {
    global auto_path

    set ::ctable::buildPath $dir

    if {[lsearch -exact $auto_path $dir] < 0} {
        lappend auto_path $dir
    }
}

package provide ctable $::ctable::ctablePackageVersion
