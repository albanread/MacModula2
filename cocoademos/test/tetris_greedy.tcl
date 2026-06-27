# Demonstrates the `get` state-query verb: the script plays ADAPTIVELY, reading
# `get height <c>` to drop each piece on the lowest column and branching on
# `get gameover` / `get flashing`. (A naive lowest-column greedy buries holes —
# and S/Z pieces always notch flat ground — so it fills to game-over rather than
# clearing; an actual scripted line-clear would need a hole-avoiding placement AI.
# What this proves: scripts can read demo state and make decisions from it.)
set i 0
while {[get gameover] == 0 && [get flashing] == 0 && $i < 90} {
  # find the lowest column
  set best 0
  set bh [get height 0]
  set c 1
  while {$c < 10} {
    set h [get height $c]
    if {$h < $bh} { set bh $h; set best $c }
    incr c
  }
  # slam to the left wall, step right to that column, hard-drop
  key left; key left; key left; key left; key left; key left
  set j 0
  while {$j < $best} { key right; incr j }
  key drop
  incr i
}
puts "dropped $i pieces   lines=[get lines]   flashing=[get flashing]   over=[get gameover]"
if {[get flashing] > 0} {
  snap /tmp/tetris_flash.png
  puts "FLASH captured (full row(s) lit white, not yet collapsed)"
  step 1
  snap /tmp/tetris_cleared.png
  puts "collapsed: lines now [get lines], score [get score]"
} else {
  snap /tmp/tetris_noclear.png
  puts "no line completed (gameover=[get gameover])"
}
puts done
