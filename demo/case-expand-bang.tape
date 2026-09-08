# With expand_bang, ! expands to the previous command even when it failed: after
# a command that was not found, :Bang echo ! writes that command's name.
Output demo/case-expand-bang.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'hello' > "$F"; nvim --clean -u demo/_init.lua -c 'set cmdheight=3' "$F"`
Enter
Sleep 800ms
Show

Type ":let g:bang = #{expand_bang: v:true}"
Sleep 300ms
Enter
Sleep 800ms
Type ":Bang nosuchcmd"
Sleep 300ms
Enter
Sleep 2000ms
Type ":Bang echo !"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
