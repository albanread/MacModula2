key enemy
key enemy
key enemy
set p [get score]
set i 0
while {$i < 70} {
  key fire
  step 3
  set s [get score]
  if {$s > $p} { snap cocoademos/gallery/img/starturret.png; set i 999 }
  set p $s
  incr i
}
if {$i < 999} { snap cocoademos/gallery/img/starturret.png }
puts done
