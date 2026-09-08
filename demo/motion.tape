# A motion filters exactly the text it covers: g!iw on one word, charwise.
# The built-in ! would take the whole line.
Output demo/motion.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'The quick brown fox jumps.' 'over the lazy dog.' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "0ww"
Sleep 600ms
Type "g!iw"
Sleep 600ms
Type "tr a-z A-Z"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
