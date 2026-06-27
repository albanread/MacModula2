# Headless test for synth_cocoa — the scope + spectrum are rendered from the real
# rendered samples, so they differ by waveform even with no live audio.
key c
step 2
snap /tmp/synth_a.png
puts "sine C: wave=[get wave] note=[get note]"

key wave
key wave
key g
step 2
snap /tmp/synth_b.png
puts "saw G: wave=[get wave] note=[get note]"

key auto
step 45
snap /tmp/synth_c.png
puts "auto: auto=[get auto] events=[get events] note=[get note]"
puts done
