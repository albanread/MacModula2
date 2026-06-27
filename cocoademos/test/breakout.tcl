# Headless smoke test for breakout_cocoa — serve the ball and let the physics run;
# confirm bricks break (score up, brick count down) via the get state-query verb.
snap /tmp/brk_a.png
puts "start: bricks=[get bricks] launched=[get launched]"

key space
step 80
snap /tmp/brk_b.png
puts "after serve: score=[get score] bricks=[get bricks]"

step 140
snap /tmp/brk_c.png
puts "score=[get score]  bricks=[get bricks]  lives=[get lives]  level=[get level]"
puts done
