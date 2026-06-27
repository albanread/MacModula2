# Headless smoke test for tetris_cocoa — hold, 7-bag pieces, stacking.
snap /tmp/tetris_a.png
puts "start (first piece, hold empty, next preview)"

# stash the first piece into HOLD
key hold
snap /tmp/tetris_b.png
puts "after hold (HOLD box filled, new piece active)"

# play several pieces across the floor with hard drops + rotations
key left; key left; key left; key left; key drop
key rotate; key left; key left; key drop
key drop
key right; key right; key right; key drop
key rotate; key right; key right; key right; key right; key right; key drop
key left; key drop
key right; key right; key right; key right; key drop
snap /tmp/tetris_c.png
puts "stack building (7-bag variety)"
puts done
