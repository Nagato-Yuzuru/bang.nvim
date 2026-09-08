# A blockwise selection filters one column: <C-v> down the numbers, g!, sort.
# The names to the left stay where they are.
Output demo/block.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'apple   30' 'mango   10' 'kiwi    20' 'pear    40' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "0"
Type "8l"
Sleep 600ms
Ctrl+V
Type "3jl"
Sleep 800ms
Type "g!"
Sleep 600ms
Type "sort"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
