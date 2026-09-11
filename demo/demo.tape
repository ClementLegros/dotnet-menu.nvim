# Records demo.gif with VHS (https://github.com/charmbracelet/vhs).
#
#   demo/setup.sh && vhs demo/demo.tape      (from the repo root)
#
# Needs roslyn-language-server, the .NET SDK and a Nerd Font. DEMO_DIR must
# match what setup.sh used (default /tmp/dotnet-menu-demo).

Output demo/demo.gif

Require nvim
Require dotnet

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 17
Set Width 1300
Set Height 780
Set Padding 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms
Set Framerate 20
Set CursorBlink false

# Start Neovim off camera and give roslyn_ls time to load the solution.
Hide
Type 'export REPO="$PWD" NVIM_APPNAME=dotnet-menu-demo && cd "${DEMO_DIR:-/tmp/dotnet-menu-demo}/Shop" && clear' Enter
Type 'nvim -u "$REPO/demo/init.lua" Shop.Core/Order.cs' Enter
Sleep 12s
Type ":lua require('notify').dismiss({ silent = true, pending = true })" Enter
Type ":echo" Enter
Sleep 500ms
Show

Sleep 1.5s

# 1. Menu: new file
Alt+a
Sleep 1.5s
Type " n"
Sleep 1.8s
Type "f"
Sleep 1.2s
Type "c"
Sleep 800ms
Type "Models/Customer"
Sleep 600ms
Enter
Sleep 3s

# 2. oil: create a file
Alt+b
Type "-"
Sleep 800ms
Type "-"
Sleep 1.2s
Type "Go"
Sleep 300ms
Type "IOrderService.cs"
Escape
Sleep 500ms
Type ":w"
Enter
Sleep 2.5s
Type "/IOrderService"
Enter
Enter
Sleep 2.5s

# 3. oil: rename a file
Alt+c
Type "-"
Sleep 1.2s
Type "/Product"
Enter
Sleep 500ms
Type "ciwItem"
Escape
Sleep 700ms
Type ":w"
Enter
Sleep 3s
Type "/ Order.cs"
Enter
Enter
Sleep 3.5s

# 4. oil: move a file to another folder
Alt+d
Type "-"
Sleep 1.2s
Type "/ Item.cs"
Enter
Sleep 400ms
Type "dd"
Sleep 600ms
Type "/Models"
Enter
Enter
Sleep 1s
Type "p"
Sleep 700ms
Type ":w"
Enter
Sleep 6s
Type "-"
Sleep 1s
Type "/ Order.cs"
Enter
Enter
Sleep 4s

# 5. oil: delete a file that is still used
Alt+e
Type "-"
Sleep 1s
Type "/Models"
Enter
Enter
Sleep 1s
Type "/ Item.cs"
Enter
Sleep 400ms
Type "dd"
Sleep 600ms
Type ":w"
Enter
Sleep 1.5s
Type "y"
Sleep 2s
Alt+f
Sleep 4s
