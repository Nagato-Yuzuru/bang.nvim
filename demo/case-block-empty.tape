# A command that writes nothing clears the block: a block over the numbers, g!,
# true, and the text after the block moves left.
Output demo/case-block-empty.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'a 1 x' 'b 2 x' 'c 3 x' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "0"
Type "2l"
Sleep 600ms
Ctrl+V
Type "2jl"
Sleep 800ms
Type "g!"
Sleep 600ms
Type "true"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
