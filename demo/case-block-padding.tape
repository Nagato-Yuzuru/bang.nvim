# Output rows of unequal width are padded: a one-cell block over the numbers,
# g!, awk squares them into one- and two-digit results, and the x column moves
# right by one on every line and stays aligned.
Output demo/case-block-padding.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'a 2 x' 'b 4 x' 'c 8 x' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "0"
Type "2l"
Sleep 600ms
Ctrl+V
Type "2j"
Sleep 800ms
Type "g!"
Sleep 600ms
Type "awk '{print $1*$1}'"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
