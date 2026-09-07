# . repeats the last g!: same motion, same command, no prompt.
# g!ip sorts the first paragraph; . on the second sorts it too.
Output demo/repeat.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'banana' 'apple' 'cherry' '' 'fig' 'elderberry' 'grape' > "$F"; nvim --clean --cmd 'set rtp^=.' -c 'runtime plugin/bang.lua' -c 'set laststatus=0 nonumber noswapfile cmdheight=2' "$F"`
Enter
Sleep 800ms
Show

Type "g!ip"
Sleep 600ms
Type "sort"
Sleep 300ms
Enter
Sleep 1500ms
Type "5G"
Sleep 600ms
Type "."
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
