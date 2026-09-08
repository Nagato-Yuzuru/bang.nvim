# A readonly buffer warns W10 once, as any other change does: nvim -R, g!ip,
# sort, and the paragraph is sorted under one warning.
Output demo/case-readonly.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'banana' 'apple' 'cherry' > "$F"; nvim -R --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "g!ip"
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
