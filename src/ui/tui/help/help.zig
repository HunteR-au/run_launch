pub fn getHelpString() []const u8 {
    return 
    \\      ==========
    \\      =Controls=
    \\      ==========
    \\
    \\F2                    ---> display help
    \\W                     ---> Select left OutputView
    \\E                     ---> Select Right OutputView
    \\Tab                   ---> Next Output
    \\Shift+Tab             ---> Previous Output
    \\S                     ---> Move Output left
    \\D                     ---> Move Output right
    \\S+Shift               ---> Split Output left
    \\D+Shift               ---> Split Output right
    \\/                     ---> Open cmd window
    \\U                     ---> page up
    \\I                     ---> page down
    \\U+Ctrl                ---> Scroll to bottom
    \\I+Ctrl                ---> Scroll to top
    \\Mwheel down           ---> Scroll down
    \\Mwheel up             ---> Scroll up
    \\J or down arrow       ---> Scroll down 1
    \\K or up arrow         ---> Scroll up 1
    \\J+Ctrl                ---> Scroll down 5
    \\K+Ctrl                ---> Scroll up 5
    \\
    \\      ==========
    \\      =Commands=
    \\      ==========
    \\
    \\  - Note: Arguments can be in quotes
    \\
    \\
    \\keep str1 str2 ... strn
    \\      
    \\      - Keep lines that match any of the following regex patterns
    \\
    \\hide str1 str2 ... strn
    \\      
    \\      - Hide lines that match any of the following regex patterns
    \\
    \\unfilter
    \\
    \\      - Remove any keep/hide filters from the buffer
    \\
    \\replace {str1 str2} {str3 str4} ... {strn-1 strn}
    \\
    \\      - Replace any regex matches with the following string
    \\
    \\unreplace
    \\
    \\      - Remove all string replacements
    \\
    \\color pattern fg:color:bg:color:line
    \\
    \\      - Color any regex matches, arguments are broken up by ":"
    \\          - {opt} bg following a color arg - colors the background
    \\          - {opt} fg following a color arg - colors the foreground
    \\          - {opt} adding line colors the line containing a match
    \\          - color can be of the form
    \\              strings - red, green, yellow, blue, 
    \\                        magenta, cyan, white, black
    \\              d+,d+,d+ where each number is 0-255
    \\              
    \\uncolor
    \\
    \\      - Remove any color cmds
    \\
    \\find str
    \\
    \\      - Find a regex pattern str from the top of your output window wrapping
    \\          around
    \\
    \\next
    \\
    \\      - If find is active, will move to the next match
    \\
    \\prev
    \\
    \\      - If find is active, will move to the previous match
    \\
    \\j n     
    \\
    \\      - jump to line n
    ;
}
