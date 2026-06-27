# Headless smoke test for asteroids_cocoa — render, then spray-fire in a sweep and
# confirm rocks get hit (score climbs) using the get state-query verb.
snap /tmp/ast_a.png
puts "start"

# rotate-and-fire sweep: spray bullets in all directions while time advances
set i 0
while {$i < 30} {
  key fire
  key left
  step 4
  incr i
}
snap /tmp/ast_b.png
step 40
snap /tmp/ast_c.png
puts "score=[get score]  asteroids=[get asteroids]  wave=[get wave]  lives=[get lives]  over=[get gameover]"
puts done
