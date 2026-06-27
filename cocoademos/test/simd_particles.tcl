# Headless smoke test for simd_particles_cocoa.
# Let the swirl evolve, snapshot it, toggle pause, reseed, snapshot again.
step 200
snap /tmp/simd_particles_a.png
puts "snapped a"
key r
step 60
snap /tmp/simd_particles_b.png
puts "snapped b"
puts done
