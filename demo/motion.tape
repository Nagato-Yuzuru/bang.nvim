# A motion filters exactly the text it covers: g!iW on a YAML value, charwise.
# base64 encodes the value where it stands and base64 -d brings it back; the
# key beside it never changes. The built-in ! would take the whole line.
Output demo/motion.gif
Source demo/_theme.tape

Hide
Type@5ms `F=/tmp/bang-demo-$$.yaml; printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'metadata:' '  name: db' 'data:' '  password: hunter2' > "$F"; nvim --clean -u demo/_init.lua "$F"`
Enter
Sleep 800ms
Show

Type "G^W"
Sleep 600ms
Type "g!iW"
Sleep 600ms
Type "base64"
Sleep 300ms
Enter
Sleep 2000ms
Type "g!iW"
Sleep 600ms
Type "base64 -d"
Sleep 300ms
Enter
Sleep 2500ms

Hide
Type ":qa!"
Enter
Type `rm -f "$F"`
Enter
