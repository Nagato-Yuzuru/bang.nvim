# A block edge inside a double-width character takes the whole character: the
# block is two cells wide, and both characters it touches on the middle row flip.
Output demo/case-block-wide-char.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf 'abcdef\n\346\227\245\346\234\254\350\252\236\nabcdef\n' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "0"
Type "l"
Sleep 600ms
Ctrl+V
Type "2jl"
Sleep 800ms
Type "g!"
Sleep 600ms
Type "rev"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
