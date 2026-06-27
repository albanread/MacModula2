# Exercise the new Asteroids features: lurking saucer + ship-explosion debris.
# Spawn a saucer, let it drift and shoot at the (stationary, central) ship; the
# saucer's aimed bullets should hit the ship and burst it into debris.
snap /tmp/ast2_a.png
puts "start saucer=[get saucer]"

key saucer
step 16
snap /tmp/ast2_b.png
puts "saucer in play: saucer=[get saucer] lives=[get lives]"

step 70
snap /tmp/ast2_c.png
puts "after volley: saucer=[get saucer] lives=[get lives] score=[get score]"

step 40
snap /tmp/ast2_d.png
puts done
