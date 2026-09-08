# A charwise `$` selection stops at the last character: v$, g!, rev flips the
# line, and the line break stays, so the next line stays where it was.
Output demo/case-charwise-dollar.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'abc def' 'next line' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "v$"
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
