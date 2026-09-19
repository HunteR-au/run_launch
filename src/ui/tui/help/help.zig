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
    \\Mouse drag            ---> Select output text (copied on release, line numbers excluded)
    \\Y                     ---> Copy the selection again
    \\Esc                   ---> Clear the selection / search
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
    \\
    \\lines {--all on|off}
    \\
    \\      - toggle focused output lines on or off OR
    \\          set for all outputs
    \\
    \\wrap {--all on|off}
    \\
    \\      - toggle soft wrapping of long lines for the focused output OR
    \\          set for all outputs
    \\
    \\render {--all terminal|raw}
    \\
    \\      - toggle the view of the focused output OR set for all outputs
    \\          terminal: output as a terminal would show it (colours, \r
    \\                    overwrites, tabs); filters, color and find apply
    \\          raw:      the stored bytes as written, every control byte
    \\                    visible (^[[31m, ^M, ^G, \xFF); no filters, styles
    \\                    or find. Switching back leaves the terminal view intact
    \\
    \\merge view_name { --all | { ~m ... ~n } }
    \\
    \\      - merge the text of multiple views together sorted via the 
    \\          timestamp of each line into a new view called view_name
    \\
    \\stop { ~n | !n } ...
    \\
    \\      - titles can repeat, so only these ids are accepted (F1 lists them)
    \\          ~n: remove view n and its buffer; a view backed by a child
    \\              process also kills that process; a merged view is unlinked
    \\              and merges built on it keep their lines
    \\          !n: kill the child process behind buffer n, keep the view; the
    \\              process-exited marker appears at the end of the output
    \\              (merged/help buffers have no process: nothing happens)
    \\          with no views left the app keeps running: start something or q
    ;
}
