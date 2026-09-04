# Demo GIF for bang.nvim v0.1.0 (issue #15).
#
# One take: g!ip+sort, `.` repeats it on another paragraph, g!iw+tr on a word,
# a blockwise <C-v> g!+sort on a column, then g!ip+false to show the failure
# guarantee. The buffer is written by this tape (Hidden) to a private temp
# file, so a clean checkout regenerates the same recording; nothing is left
# in the repository.

Output bang.gif

Set FontSize 20
Set Width 980
Set Height 500
Set Theme "Dracula"
Set TypingSpeed 60ms
Set Framerate 15

Hide
Type@5ms `F=/tmp/bang-demo-$$.txt; printf '%s\n' 'banana' 'apple' 'cherry' 'date' '' 'fig' 'elderberry' 'grape' 'honeydew' '' 'The quick target fox jumps.' '' 'apple   30' 'mango   10' 'kiwi    20' '' 'zebra' 'yak' 'xray' 'wolf' > "$F"; nvim --clean --cmd 'set rtp^=.' -c 'runtime plugin/bang.lua' -c 'set laststatus=0 nonumber noswapfile cmdheight=2' "$F"`
Enter
Sleep 800ms
Show

# 1. g!ip, sort: the paragraph is sorted.
Type "g!ip"
Sleep 500ms
Type "sort"
Sleep 200ms
Enter
Sleep 2s

# 2. `.` right after step 1: repeats g!ip+sort on another paragraph, no prompt.
Type "6G0"
Sleep 300ms
Type "."
Sleep 2s

# 3. g!iw, tr a-z A-Z: only the word under the cursor changes. Charwise.
Type "11G0ww"
Sleep 300ms
Type "g!iw"
Sleep 500ms
Type "tr a-z A-Z"
Sleep 200ms
Enter
Sleep 2s

# 4. <C-v> down a column, g!, sort: only the column reorders. Blockwise.
Type "13G08l"
Sleep 300ms
Ctrl+V
Type "ljj"
Sleep 300ms
Type "g!"
Sleep 500ms
Type "sort"
Sleep 200ms
Enter
Sleep 2s

# 5. g!ip, false: the error shows at the bottom, the text stays.
# Land on the paragraph's last line first, so the window scrolls to show all
# of it before `ip` snaps the cursor back to its top line.
Type "20G0"
Sleep 300ms
Type "g!ip"
Sleep 500ms
Type "false"
Sleep 200ms
Enter
Sleep 2.5s

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
