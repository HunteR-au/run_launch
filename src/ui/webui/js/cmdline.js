// TODO: create an event that should fire when a cmd is created so that anything can add their commands to it
// TODO: create feedback when a command is missing or the args are wrong...
// TODO: need to be able to parse args with spaces
// - create color rules without using the sidebar
// - maybe a flush buffer command...
// - help command which spawns a new outputview with help info
// - jump command
// - press '/' to cycle through active cmd bars

// Map input.id to object
g_commandBars = new Map();

class CommandBar {
  constructor(processName) {
    this.cmdHandlers = new Map();
    this.processName = processName;
    g_commandBars.set('cmdbar-'+processName, this);

    // NOTE - the code below is just here for debugging
    addFoldCommand(this);
    addUnfoldCommand(this);
    addSwitchTab(this);
  }

  getReferencedOutputView() {
    return outputviews[this.processName];
  }
    
  runCommand(cmdstr) {
    // Split the string via the first ':' char. The zeroth part is the cmd name
    // and the rest is the arguments
    let tokens = cmdstr.split(":");

    // find a handler match
    for (const [cmdName, func] of this.cmdHandlers) {
      if (cmdName == tokens[0]) {
        // match found...run the cmd handler
        let args = this.handleArguments(tokens[1]);
        func(args, this.getReferencedOutputView());
      }
    }
  }

  handleArguments(argstr) {
    // const regex = /\s+/;
    // return argstr.split(regex);
    return argstr.match(/\S+/g) || [];
  }

  createCmdBarEl() {
    function _createEvents(cmdbarEl) {
      cmdbarEl.addEventListener('keydown', function(e) {
        if (event.key === 'Enter') {
          let cmdbarobj = g_commandBars.get(this.id);
          console.log("Looking for obj...");
          if (cmdbarobj != null) {
            console.log("Found obj")
            cmdbarobj.runCommand(e.target.value);
          }
        }
      })
    }
    
    let cmdBarEl = document.createElement('input');
    cmdBarEl.setAttribute('type', 'text');
    cmdBarEl.className = 'cmdbar';
    cmdBarEl.id = 'cmdbar-'+this.processName;
    cmdBarEl.style.display = 'none';
    _createEvents(cmdBarEl);
    return cmdBarEl;
  }

  addCommand(name, func) {
    if (!(typeof name === 'string' && typeof func === 'function')) {
      throw "CommandBar.AddCommand: TypeError";
    }
    
    this.cmdHandlers.set(name, func);
  }
}


// class Command {
//   constructor(cmdname, cmdfunc) {
//     this.name = cmdname;
//     this.func = cmdfunc;
//   }
// }


function addFoldCommand(commandBar) {
  function handler(args, outputViewObj) {
    // arguments
    // 1...n) regex strings to match lines we want to fold around

    // validate that each arg in args is a string
    for (arg in args) {
      if (typeof arg !== 'string') {
        throw "FoldCommandHandler: TypeError";
      }
    }

    // start folding
    console.log("START folding...");
    console.log(args);
    outputViewObj.fold(args);
  }
  commandBar.addCommand("fold", handler);
}

function addUnfoldCommand(commandBar) {
  function handler(args, outputViewObj) {
    for (arg in args) {
      if (typeof arg !== 'string') {
        throw "UnfoldCommandHandler: TypeError";
      }
    }
    outputViewObj.unfold();
  }
  commandBar.addCommand("unfold", handler);
}

function addColorRule(commandBar) {
  function handler(args, outputViewObj) {
    // color: pattern color {global} 
  }
  commandBar.addCommand("color", handler);
}

function addSwitchTab(commandBar) {
  function handler(args, outputViewObj) {
    if (args.length == 0) {
      return;
    }
    
    const parentGroup = outputViewObj.getParentViewGroup();
    const tabs = parentGroup.getTabs();
    for (let tab of tabs) {
      if (tab.innerText === args[0]) {
        parentGroup.setActiveTab(tab);
      }
    }
  }
  commandBar.addCommand("t", handler);
}
