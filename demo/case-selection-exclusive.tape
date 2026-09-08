# 'selection' is honoured: with exclusive, the character under the cursor stays
# out, so v2l then g! + tr a-z A-Z changes two letters, not three.
Output demo/case-selection-exclusive.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'abcdef' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type ":set selection=exclusive"
Sleep 300ms
Enter
Sleep 800ms
Type "v2l"
Sleep 800ms
Type "g!"
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
