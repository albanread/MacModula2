# Headless test for starturret_cocoa — render the 3D starfield, bring a fighter in,
# let it shoot asterisk bolts at the (un-dodged, central) turret -> hit flash + life.
snap /tmp/turret_a.png
puts "warp start"

key enemy
step 45
snap /tmp/turret_b.png
puts "fighter approaching: enemies=[get enemies]"

step 70
snap /tmp/turret_c.png

step 30
snap /tmp/turret_d.png
puts "result: lives=[get lives] score=[get score] enemies=[get enemies] flash=[get flash]"
puts done
