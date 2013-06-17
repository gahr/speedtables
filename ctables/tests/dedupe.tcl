#!/usr/local/bin/tclsh8.5

package require speedtable

CExtension duper 1.0 {
    CTable Superduper {
        varstring alpha
        varstring beta indexed 1
        varstring delta
        dedupestring gamma indexed 1
    }

}

package require Duper


if {1} {
    puts "using shmem"
    Superduper create mysuperduper master name "moo3" file "mysuperduper.dat" size "256M"
} else {
    puts "using mem"
    Superduper create mysuperduper
}

puts "created"

#
# Store some stuff in the table.
#
for {set i 0} {$i < 10000} {incr i} {
	set imod10 [expr {$i % 10}]
    mysuperduper store [list alpha alfa$i beta bravo$i delta delta$imod10 gamma golf$imod10 ]
}

puts "inserted"

#
# Query some stuff from the table.
#
mysuperduper search -array barnrow -limit 10 -sort alpha -code {
    set count [array size barnrow]
    if {$count != 4} {
        puts "Error: wrong number of elements (was $count, expected 5)"
    }
    parray barnrow
    puts ""
}

puts info=[mysuperduper share info]
#puts pools=[mysuperduper share pools]
puts free=[mysuperduper share free]




puts "done"

