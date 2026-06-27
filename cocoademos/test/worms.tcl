# Headless smoke test for worms_cocoa — exercises the coroutine AI + steering.
step 1
snap /tmp/worms_a.png
puts "start snapped"
# let the worms hunt treats for a while (coroutines decide each tick)
step 40
key right
step 8
key down
step 8
snap /tmp/worms_b.png
puts "mid snapped"
step 60
snap /tmp/worms_c.png
puts done
