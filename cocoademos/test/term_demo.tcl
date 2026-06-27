# Headless UI test for term_demo_cocoa — drives the menu bar and the field.
snap /tmp/term_a.png
puts "initial (field focus)"

# focus the menu bar and open File
key tab
key down
snap /tmp/term_b.png
puts "File menu open"

# walk across to the View menu, pick Toggle Help, choose it
key right
key right
key down
key down
snap /tmp/term_c.png
puts "View > Toggle Help highlighted"
key enter
snap /tmp/term_d.png
puts "help toggled (status updates)"

# back to the field, type a name, submit
key tab
key A
key d
key a
snap /tmp/term_e.png
puts "typed into field"
key enter
snap /tmp/term_f.png
puts done
