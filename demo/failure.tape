# A failing command leaves the buffer alone: a mistyped name, the message shows,
# the text stays.
# The built-in ! would replace the paragraph with the error.
Output demo/failure.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'banana' 'apple' 'cherry' > "$F"; nvim --clean -u demo/_init.lua -c 'set cmdheight=3' "$F"`
Enter
Sleep 800ms
Show

Type "g!ip"
Sleep 600ms
Type "sorrt"
Sleep 300ms
Enter
Sleep 3000ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
