// Example string buffer
let buffer = `This is an example string buffer.
It will be rendered line by line in a command-line-like prompt.
Feel free to expand this string buffer to see how it handles larger inputs.`;

let buffer2 = `This is an example string buffer.
It will be rendered line by line in a command-line-like prompt.
Feel free to expand this string buffer to see how it handles larger inputs.
An AI builds a programming puzzle.
The cat appreciates the universe.
The astronaut appreciates a moon rock.
An AI appreciates a moon rock.
The cat jumps over a programming puzzle.
A robot explores the universe.
An AI appreciates the universe.
A robot analyzes a random sentence.
 robot explores the universe.
My friend jumps over a moon rock.
My friend appreciates a programming puzzle.
The cat analyzes the universe.
The cat analyzes a random sentence.
The cat builds the universe.
The astronaut explores a programming puzzle.
A robot explores a moon rock.
My friend jumps over a random sentence.
The cat explores a moon rock.
The cat explores a random sentence.
A robot jumps over a programming puzzle.
The astronaut explores a random sentence.
The cat jumps over a large tree.
My friend builds a moon rock.
The cat explores a programming puzzle.
The cat appreciates the universe.
The astronaut explores a large tree.
The astronaut analyzes a programming puzzle.
The astronaut appreciates a programming puzzle.
The cat appreciates a moon rock.
The cat builds a moon rock.
The astronaut analyzes a large tree.
The cat appreciates the universe.
An AI analyzes a programming puzzle.
A robot appreciates a random sentence.
My friend analyzes a random sentence.
An AI analyzes a moon rock.
My friend jumps over a moon rock.
A robot builds the universe.
My friend analyzes a programming puzzle.
The astronaut appreciates a moon rock.
The astronaut explores the universe.
My friend appreciates a programming puzzle.
A robot analyzes the universe.
My friend builds a random sentence.
My friend explores a random sentence.
A robot appreciates a random sentence.
A robot builds the universe.
The astronaut builds a moon rock.
A robot appreciates the universe.
The cat analyzes a moon rock.
A robot appreciates a large tree.
An AI explores a large tree.
An AI explores the universe.
My friend explores a programming puzzle.
My friend jumps over a moon rock.
A robot analyzes a random sentence.
The astronaut appreciates a programming puzzle.
The astronaut jumps over the universe.
My friend appreciates a large tree.
My friend appreciates a random sentence.`

let viewgroups = {}
let outputviews = {}
let currentLines = {}
let uiConfig = null;
// Split the buffer into lines
//let lines = buffer.split("\n");

// Reference the output div and button
const outputDiv = document.getElementById("output");
const nextLineButton = document.getElementById("nextLine");

function generateRandomSentence() {
    // Define arrays of words
    const subjects = ["The cat", "A robot", "The astronaut", "My friend", "An AI"];
    const verbs = ["jumps over", "analyzes", "explores", "builds", "appreciates"];
    const objects = ["a moon rock", "a programming puzzle", "a large tree", "the universe", "a random sentence"];
  
    // Pick random words from each array
    const randomSubject = subjects[Math.floor(Math.random() * subjects.length)];
    const randomVerb = verbs[Math.floor(Math.random() * verbs.length)];
    const randomObject = objects[Math.floor(Math.random() * objects.length)];
  
    // Combine the words into a sentence
    const sentence = `${randomSubject} ${randomVerb} ${randomObject}.`;
  
    return sentence;
  }

function setUIConfig(jsonConfigStr) {
  uiConfig = JSON.parse(jsonConfigStr);
  preloadSideBarFromUiConfig(uiConfig)
}

function addRandomToBuffer(processName) {
  outputviews[processName].addToBuffer('\n' + generateRandomSentence());
}

let viewGroupInitCount = 0;
function createViewGroup() {
  let count = viewGroupInitCount;  
  viewGroupInitCount = viewGroupInitCount + 1;
  
  let viewgroupdiv = document.createElement('div');
  viewgroupdiv.classList.add('viewgroup');
  viewgroupdiv.id = 'view-group-' + count;
  
  // add tab-group
  let tabGroup = document.createElement('div');
  tabGroup.className = 'tab-group';
  viewgroupdiv.appendChild(tabGroup);

  // add output-group
  let outputGroup = document.createElement('div');
  outputGroup.className = 'output-group';
  viewgroupdiv.appendChild(outputGroup);
  addDropAreaEvents(outputGroup);
  
  var viewgroup = {
    div: viewgroupdiv,

    cmdBars: new Map(),
    
    getTabCount: function getTabCount() {
      let tabgroup = this.div.getElementsByClassName('tab-group')[0];
      return tabgroup.getElementsByClassName('tablinks').length;
    },

    getTabs: function getTabs() {
      const tabgroup = this.div.getElementsByClassName('tab-group')[0];
      return Array.from(tabgroup.getElementsByClassName('tablinks'));
    },

    getViewGroupPosition: function getViewGroupPosition() {
      // get parent div (ie views)
      const viewEl = this.div.parentElement;

      // iterate through child elements until match self
      var children = viewEl.children;
      var viewGroupCount = 0
      for (var i = 0; i < children.length; i++) {
        if (children[i] == this.div) {
          // we have matched ourself
          return viewGroupCount;
        } else {
          if (children[i].classList.contains('viewgroup')) {
            viewGroupCount++;
          }
        }
      }
      throw new Error("getViewGroupPosition: Could not find self!");
    },

    remove: function remove() {
      if (this.getViewGroupPosition() == 0) {
        // the left most viewgroup, remove right divider
        let nextEL = this.div.nextElementSibling;
        if (nextEL != null && nextEL.classList.contains("viewgroup-divider")) {
          nextEL.remove();
        }
      } else {
        // not the left most viewgroup, remove left divider
        let prevEL = this.div.previousElementSibling;
        if (prevEL != null && prevEL.classList.contains("viewgroup-divider")) {
          prevEL.remove();
        }
      }

      delete viewgroups[this.div.id];
      this.div.remove();
    },

    addNewProcessToGroup: function addNewProcessToGroup(processname) {
      createTab(processname, this.div);
      createOutput(processname, this.div);
      
      console.log("create command bar" + processname);
      let cmdbar = new CommandBar(processname);
      let outputGroupDiv = this.div.getElementsByClassName('output-group')[0];
      outputGroupDiv.appendChild(cmdbar.createCmdBarEl());
      this.cmdBars.set(processname, cmdbar);
    },

    createNewOutputView: function createNewOutputView(processname) {
      // check that the processName is unique
      if (processname in outputviews) {
        return false;
      }

      outputviews[processname] = new OutputView(processname);

      // the view-group is currently hardcoded 
      let viewgroupdiv = this.div

      createTab(processname, viewgroupdiv);
      createOutputDiv(processname, viewgroupdiv);

      // creat a cmd bar for the outputview
      let cmdbar = new CommandBar(processname);
      let outputGroupDiv = this.div.getElementsByClassName('output-group')[0];
      outputGroupDiv.appendChild(cmdbar.createCmdBarEl());
      this.cmdBars.set(processname, cmdbar);

      return true;
    },
    
    getActiveOutputView: function getActiveOutputView() {
      let outputViewDivs = this.div.getElementsByClassName('output-group')[0].getElementsByClassName('tabcontent')
      for (let i = 0; i < outputViewDivs.length; i++) {
        if (outputViewDivs[i].style.display == 'block') {
          return outputviews[outputViewDivs[i].id]
        }
      }
      return null;
    },

    getActiveOutputViewDiv: function getActiveOutputViewDiv() {
      let outputViews = this.div.getElementsByClassName('output-group')[0].getElementsByClassName('tabcontent')
      for (let i = 0; i < outputViews.length; i++) {
        if (outputViews[i].style.display == 'block') {
          return outputViews[i]
        }
      }
      return null;
    },

    // Check if there are dividers on the left/right as required
    createViewGroupDividers: function createViewGroupDividers() {
      // get an array of all the viewgroups in the view
      const viewDiv = document.getElementById("views");
      const viewGroupArray = Array.from(viewDiv.children).filter(
        child => child.tagName === "DIV" && child.classList.contains("viewgroup")
      );
      if (this.div.id === viewGroupArray[0].id) {
        // the left most viewgroup
        let el = this.div.nextElementSibling;
        if (el != null && !el.classList.contains("viewgroup-divider")) {
          this.div.insertAdjacentElement("afterend", newGroupDivider());
        }
      } else if (this.div.id === viewGroupArray[viewGroupArray.length-1].id) {
        // the right most viewgroup
        let el = this.div.previousElementSibling;
        if (el != null && !el.classList.contains("viewgroup-divider")) {
          this.div.insertAdjacentElement("beforebegin", newGroupDivider());
        }
      } else {
        // check both sides
        let el = this.div.previousElementSibling;
        if (el != null && !el.classList.contains("viewgroup-divider")) {
          this.div.insertAdjacentElement("beforebegin", newGroupDivider());
        }
        el = this.div.nextElementSibling;
        if (el != null && !el.classList.contains("viewgroup-divider")) {
          this.div.insertAdjacentElement("afterend", newGroupDivider());
        }
      }
    },

    // createViewGroupDivider: function createViewGroupDivider(position, viewGroupDiv) {
    //   // check if there is already a divider before creating one
    //   if (position === 'beforebegin') {
    //     const el = this.div.previousElementSibling;
    //     if (el != null && el.classList.contains("viewgroup-divider")) {
    //       return;
    //     }
    //   } else if (position === 'afterend') {
    //     const el = this.div.nextElementSibling;
    //     if (el != null && el.classList.contains("viewgroup-divider")) {
    //       return;
    //     }
    //   }
    //   var newDivider = newGroupDivider()
    //   this.div.insertAdjacentElement(position, newDivider);
    // },

    applyViewGroupRelToSelf: function applyViewGroupRelToSelf(viewgroup, position) {
      if (position == 'beforebegin')
        {
          this.div.insertAdjacentElement(position, viewgroup.div);
          //this.createViewGroupDivider(position);
        }
      else if (position == 'afterend')
        {
          this.div.insertAdjacentElement(position, viewgroup.div);
          //this.createViewGroupDivider(position);
        }
    },

    setActiveTab: function setActiveTab(tab) {
      let newOutputGroup = this.div.getElementsByClassName('output-group')[0];
      let newTabGroup = this.div.getElementsByClassName('tab-group')[0];

      for (let tabcontent of newOutputGroup.getElementsByClassName('tabcontent')) {
        if (tab.innerText == tabcontent.id) {
          tabcontent.style.display = 'block';
        } else {
          tabcontent.style.display = 'none';
        }
      }
      for (let tablink of newTabGroup.getElementsByClassName('tablinks')) {
        if (tablink == tab) {
          tab.classList.add('active');
        } else {
          tablink.classList.remove('active');
        }
      }
      for (let cmdline of newOutputGroup.getElementsByClassName('cmdbar')) {
        if (cmdline.id == 'cmdbar-'+tab.innerText) {
          cmdline.style.display = 'block';
        } else {
          cmdline.style.display = 'none';
        }
      }
    },
    
    moveTab: function moveTab(tab) {
      // check if we will need to delete the tab's current view-group
      let delCurrentTabView = false;
      let tabCurrViewGroup = viewgroups[tab.parentNode.parentNode.id];

      if (tabCurrViewGroup == this) {
        // we are trying to move to self
        return false;
      }

      if (tabCurrViewGroup.getTabCount() <= 1) {
        delCurrentTabView = true;
      }

      // check if tab is current active, if so we will need to change active
      let isCurrTabActive = false;
      if (tab.classList.contains('active')) {
        isCurrTabActive = true;
      };

      let output = document.getElementById(tab.innerText);
      let cmdbar = document.getElementById('cmdbar-'+tab.innerText);
      let cmdbarObj = tabCurrViewGroup.cmdBars[tab.innerText];
      tabCurrViewGroup.cmdBars.delete(tab.innerText);
      this.cmdBars.set(tab.innerText, cmdbarObj);

      let newOutputGroup = this.div.getElementsByClassName('output-group')[0];
      let newTabGroup = this.div.getElementsByClassName('tab-group')[0];
      
      newTabGroup.appendChild(tab);
      newOutputGroup.appendChild(output);
      newOutputGroup.appendChild(cmdbar);

      this.setActiveTab(tab);

      // delete if no tabs exist
      if (delCurrentTabView) {
        tabCurrViewGroup.remove();
      } else if (isCurrTabActive) {
        let oldTabGroup = tabCurrViewGroup.div.getElementsByClassName('tab-group')[0];
        tabCurrViewGroup.setActiveTab(oldTabGroup.getElementsByClassName('tablinks')[0]);
      }
    }
  }

  // add to global map
  viewgroups[viewgroup.div.id] = viewgroup

  return viewgroup; 
}

function createTab(processname, viewgroupdiv) {
  let tab = document.createElement("button");
  tab.className = "tablinks "  
  tab.setAttribute('onclick', "openProcessView(event);");
  tab.setAttribute('draggable', 'true')
  tab.textContent = processname;
  
  // Should only be 1 tab group
  tabGroupDiv = viewgroupdiv.getElementsByClassName('tab-group')[0];
  tabGroupDiv.appendChild(tab);
  
  addDraggableEvents(tab);
}

function createOutputDiv(processname, viewgroupdiv) {
  // Should only be 1 tab group
  outputGroupDiv = viewgroupdiv.getElementsByClassName('output-group')[0];
  outputGroupDiv.insertAdjacentHTML('beforeend',
    "<div id=\""+processname+"\" class=\"tabcontent output\" style=\"display: none;\"></div>"
  );
}

class OutputView {
  constructor(processName) {
    this.processName = processName;
    this.rawBuffer = ""
    this.formattedBuffer = ""
    this.numOfLines = 0
    this.idxLastFormattedTo = 0
    this.formattingRules = new Map();
    this.isFolded = false;
    this.foldedBuffer = "";
    // An array of string to match on
    this.foldedMatches = [];
  }

  getParentViewGroup() {
    return viewgroups[this.getDiv().parentElement.parentElement.id];
  }

  getDiv() {
    return document.getElementById(this.processName);
  }
  
  addFormattingRule(ruleName, rule) {
    // TODO validation of map
    this.formattingRules.set(ruleName, rule)
  }

  removeFormattingRule(ruleName) {
    // TODO validation of map
    this.formattingRules.delete(ruleName)
  }

  addToBuffer(inputBuf) {
    this.rawBuffer += inputBuf;

    // TODO - we should just add to the end of buffers and then format
    // this is just a quick hack to get it working
    if (this.isFolded) {
      this.fold(this.foldedMatches);
    }
  }

  getFormattedBuffer() {
    let allRules = []
    if (g_globalColorRules) {
      // turn map into array
      allRules = Array.from(g_globalColorRules, ([name, value]) => value);
      allRules = allRules.concat(Array.from(this.formattingRules, ([name, value]) => value))
    } else {
      allRules = Array.from(this.formattingRules, ([name, value]) => value)
    }

    if (allRules.length > 0) {
      if (this.isFolded) {
        this.formattedBuffer = colorMatches(this.foldedBuffer, allRules)
      } else {
        this.formattedBuffer = colorMatches(this.rawBuffer, allRules)
      }
      return this.formattedBuffer
    }

    if (this.isFolded) {
      return this.foldedBuffer;
    } else {
      return this.rawBuffer;
    }
  }

  updateOutputDiv() {
    const processOutputDiv = document.getElementById(this.processName);

    // is scrolled to the bottom? Allow 1px inaccuracy by adding 1
    const isScrolledToBottom = processOutputDiv.scrollHeight - processOutputDiv.clientHeight <= processOutputDiv.scrollTop + 1

    processOutputDiv.innerHTML = this.getFormattedBuffer();
    // processOutputDiv.textContent = this.getFormattedBuffer();

    // scroll to bottom if isScrolledToBottom is true
    if (isScrolledToBottom) {
      processOutputDiv.scrollTop = processOutputDiv.scrollHeight - processOutputDiv.clientHeight
    }
  }

  fold(arrOfStrs) {
    console.log("we are folding...");
    if (arrOfStrs.length == 0) {
      this.unfold();
      return;
    }
    this.isFolded = true;
    this.foldedMatches = arrOfStrs;

    let newBuffer = "";
    let lines = this.rawBuffer.split("\n");
    let linesSkipped = 0;
    for (let line of lines) {
      // check if any folded matches match
      let isMatch = false;
      let prevLineSkipped = false;
      for (let foldedMatch of this.foldedMatches) {
        let m = line.match(foldedMatch);
        if (m) {
          // found a match
          isMatch = true;
          break;
        }
      }
      if (!isMatch) {
        linesSkipped++;
      }

      if (isMatch) {
        // need to write the num of lines skipped
        if (linesSkipped != 0) {
          newBuffer += '\n...lines skipped {'+linesSkipped+'}';
        }
        // keep the line
        newBuffer += '\n'+line;
        // cleanup
        linesSkipped = 0;
        prevLineSkipped = false;
      } else {
        prevLineSkipped = true;
      }

    }
    // need to check if last few lines were skipped
    if (linesSkipped != 0) {
      newBuffer += '\n...lines skipped {'+linesSkipped+'}';
    }

    this.foldedBuffer = newBuffer;     
    this.updateOutputDiv();
  }

  unfold() {
    // Reset the folded members to their defaults
    this.isFolded = false;
    this.foldedMatches = [];
    this.foldedBuffer = "";

    // Reset the formatted buffer
    this.updateOutputDiv();    
  }
}

function listAllOutputViewProcessNames() {
  return Object.keys(outputviews);
}

function createView(processname) {
  // check that the processName is unique
  if (processname in outputviews) {
    return false;
  }

  // outputviews[processname] = new OutputView(processname);

  // the view-group is currently hardcoded 
  let viewgroupdiv = document.getElementById("view-group-0");
  let viewgroup = viewgroups[viewgroupdiv.id];
  console.log("createNewOutputView " + processname)
  viewgroup.createNewOutputView(processname);

  // createTab(processname, viewgroupdiv);
  // createOutputDiv(processname, viewgroupdiv);

  addSideBarOutputViewSection(processname);

  // If this is the first outputview, set active
  viewgroup.setActiveTab(document.getElementsByClassName('tablinks')[0])

  return true;
}

function removeView(processname) {
  // check that the processname view exists
  if (!(processname in outputviews)) {
    return false
  }

  delete outputviews[processname];
  delete currentLines[processname];

  // the view-group is currently hardcoded 
  let viewgroupdiv = document.getElementById("view-group-0");

  // find a remove tab 
  let tabs = document.getElementsByClassName("tablinks")
  for (let tab of tabs) {
    if (tab.innerText == processname) {
      tab.remove();
    }
  }

  // find and remove the output view
  document.getElementById(processname).remove();
  
  return true
}

function renderAllActiveOutputs() {
  for (const [_, value] of Object.entries(viewgroups)) {
    value.getActiveOutputView().updateOutputDiv();
  }
}

function renderOutputIfActive(processName) {
  let outputDiv = document.getElementById(processName);
  const outputView = outputviews[processName];

  if (outputDiv && outputDiv.style.display == 'block') {
    outputView.updateOutputDiv();
  }
}

function addToBufferAndRender(processname, buffer) {
  // check if processname exists...
  if (!(processname in outputviews)) {
    createView(processname);
  }

  outputviews[processname].addToBuffer(buffer);
  renderNextLines(processname);
}

function test(str) {
    alert(str);
}

function test1() {
    alert(generateRandomSentence());
}

// Function to render the next line
function renderNextLine(processname) {
  const processOutputDiv = document.getElementById(processname);
  outputviews[processname].updateOutputDiv();
  return false;
}

function renderNextLines(processname) {
  let isMoreLines = true;
  while (isMoreLines) {
    isMoreLines = renderNextLine(processname);
  }
}

function addLinesToProcess1() {
  addRandomToBuffer("Process1");

  
  if (outputviews['Process1'].formattingRules.size == 0) {
    let rules = [
      {
        'just_pattern': false,
        'foreground_color': "0,255,0",
        'pattern': "in"
      }
    ]
    outputviews['Process1'].addFormattingRule('myrandomrule', rules[0])
  }

  renderNextLine("Process1");
}

function openProcessView(evt) {
  // get view group id
  let viewgroupdiv = evt.currentTarget.parentNode.parentNode;
  let targetViewGroup = viewgroups[viewgroupdiv.id];
  let tab = evt.currentTarget;

  targetViewGroup.setActiveTab(tab);
}

////// DRAGGGING
function handleDragStart(e) {
  this.style.opacity = '0.4';

  dragSrcEl = this;

  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/html', this.innerHTML);
}

function handleDragEnd(e) {
  this.style.opacity = '1';

  items.forEach(function (item) {
    item.classList.remove('over');
  });
}

function handleDragOver(e) {
  e.preventDefault();
  return false;
}

function handleDragEnter(e) {
  this.classList.add('over');
}

function handleDragLeave(e) {
  this.classList.remove('over');
}

function handleDrop(e) {
  e.stopPropagation();
  if (dragSrcEl !== this) {
    // swap element dragSrcEl with this 
    var el1 = this;
    var el2 = dragSrcEl;

    // check that they have the same parent
    // we don't want to switch if they are in different
    // view groups
    if (el1.parentNode === el2.parentNode) {
      swapNodes(el1, el2);
    }

    // const parent = el1.parentNode;
    // const next = el2.nextSibling === el1 ? el2 : el1.nextSibling;
    // // const nextSibling = el1.nextSibling;
    // parent.insertBefore(el2, el1);
    // parent.insertBefore(el1, next);
    // if (nextSibling) {
    //   parent.insertBefore(el2, nextSibling);
    // } else {
    //   parent.appendChild(el2);
    // }
    // el2.replaceWith(el1);
    
    // dragSrcEl.innerHTML = this.innerHTML;
    // this.innerHTML = e.dataTransfer.getData('text/html');
  }

  return false;
}

function handleDetectDropArea(e) {
  e.preventDefault();

  // only handle drop detection if the dargSrcEl is a tablink
  if (typeof dragSrcEl === 'undefined' || dragSrcEl ==  null || !dragSrcEl.classList.contains('tablinks')) {
    return;
  }

  // get the view-group object from the output-group
  let thisViewGroup = null
  for (const [key, value] of Object.entries(viewgroups)) {
    if (value.div.getElementsByClassName("output-group")[0] == this) {
      thisViewGroup = value;
    }
  }
  
  if (thisViewGroup == null) {
    throw new Error("Could not find output group object!")
  }

  let outputViewDiv = thisViewGroup.getActiveOutputViewDiv()

  var x = e.pageX - outputViewDiv.offsetLeft;
  var y = e.pageY - outputViewDiv.offsetTop;

  var percentX = (x*100) / outputViewDiv.clientWidth;
  var percentY = (y*100) / outputViewDiv.clientHeight;

  let tabcontents = this.getElementsByClassName('tabcontent');

  if (percentX < 25) {
    // left side
    this.classList.add('over-left');
    Array.from(tabcontents).forEach(el => {
      el.classList.add('over-left-color');
    });
  } else if (percentX > 75) {
    // right side
    this.classList.add('over-right');
    Array.from(tabcontents).forEach(el => {
      el.classList.add('over-right-color');
    });
  } else if (percentX > 30 && percentX < 70) {
    // in center
    this.classList.add('over-center');
    Array.from(tabcontents).forEach(el => {
      el.classList.add('over-center-color');
    });
  } else {
    this.classList.remove('over-right');
    this.classList.remove('over-left');
    this.classList.remove('over-center');

    Array.from(tabcontents).forEach(el => {
      el.classList.remove('over-left-color');
      el.classList.remove('over-right-color');
      el.classList.remove('over-center-color');
    });
  }
  return false;
}

function handleDropArea(e) {
  e.stopPropagation();
  
  // get direction area dropped on
  let viewgroup = viewgroups[this.parentNode.id];
  let srcViewGroup = viewgroups[dragSrcEl.parentNode.parentNode.id];
  let outputgroupdiv = viewgroup.div.getElementsByClassName('output-group')[0];
  let direction = null
  
  let tabcontents = this.getElementsByClassName('tabcontent');
  Array.from(tabcontents).forEach(el => {
    el.classList.remove('over-left-color');
    el.classList.remove('over-right-color');
    el.classList.remove('over-center-color');
  });

  if (outputgroupdiv.classList.contains('over-left')) {
    // clean up first
    outputgroupdiv.classList.remove('over-left');
    
    // set direction
    direction = 'beforebegin'
  } else if (outputgroupdiv.classList.contains('over-right')) {
    // clean up first
    outputgroupdiv.classList.remove('over-right');
    
    // set direction
    direction = 'afterend'
  } else if (outputgroupdiv.classList.contains('over-center')) {
    // clean up first
    outputgroupdiv.classList.remove('over-center');
    
    // move tab to new group
    viewgroup.moveTab(dragSrcEl);

    dragSrcEl = null;
    return false;
  } else {
    // no match, just clean up
    this.classList.remove('over-right');
    this.classList.remove('over-left');
    this.classList.remove('over-center');
    dragSrcEl = null;
    return false;
  }

  // if there is 1 tab in the src viewgroup there are a bunch of edge cases
  if (srcViewGroup.getTabCount() <= 1) {
    // check if the targetViewGroup matches the src viewgroup
    let srcViewGroupId = dragSrcEl.parentNode.parentNode.id;
    if (srcViewGroupId == viewgroup.div.id) {
      dragSrcEl = null;
      return false;
    }
    let viewDiv = document.getElementById("views");
    const viewGroupArray = Array.from(viewDiv.children).filter(
      child => child.tagName === "DIV" && child.classList.contains("viewgroup")
    );
    if (viewGroupArray.length >= 2) {
      // if the srcViewGroup is on the far left, target is next to it and direction is left
      if (srcViewGroupId == viewGroupArray[0].id &&
         direction == 'beforebegin' &&
          viewgroup.div.id == viewGroupArray[1].id)
      {
        dragSrcEl = null;
        return false;
      }
      // if the srcViewGroup is on the far right, target is next to it and direction is right
      const lastPos = viewGroupArray.length - 1;
      if (srcViewGroupId == viewGroupArray[lastPos].id &&
        direction == 'afterend' &&
        viewgroup.div.id == viewGroupArray[lastPost-1].id)
      {
        dragSrcEl = null;
        return false;
      }
    }
  }
  
  let newviewgroup = createViewGroup();
  viewgroup.applyViewGroupRelToSelf(newviewgroup, direction);

  // move tab to new group
  newviewgroup.moveTab(dragSrcEl);
  newviewgroup.createViewGroupDividers();
  dragSrcEl = null;
  return false;
}

function handleDragAreaLeave(e) {
  this.classList.remove('over-right');
  this.classList.remove('over-left');

  let tabcontents = this.getElementsByClassName('tabcontent');
  Array.from(tabcontents).forEach(el => {
    el.classList.remove('over-left-color');
    el.classList.remove('over-right-color');
    el.classList.remove('over-center-color');
  });
};

var draggableEventItems = Array();
function addDraggableEvents(draggableEl) {
  draggableEventItems.push(draggableEl);
  
  function handleDragStart(e) {
    this.style.opacity = '0.4';
  
    dragSrcEl = this;
  
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/html', this.innerHTML);
  }
  
  function handleDragEnd(e) {
    this.style.opacity = '1';
  
    draggableEventItems.forEach(function (item) {
      item.classList.remove('over');
    });
  }
  
  function handleDragOver(e) {
    e.preventDefault();
    return false;
  }
  
  function handleDragEnter(e) {
    this.classList.add('over');
  }
  
  function handleDragLeave(e) {
    this.classList.remove('over');
  }

  draggableEl.addEventListener('dragstart', handleDragStart);
  draggableEl.addEventListener('dragover', handleDragOver);
  draggableEl.addEventListener('dragenter', handleDragEnter);
  draggableEl.addEventListener('dragleave', handleDragLeave);
  draggableEl.addEventListener('dragend', handleDragEnd);
  draggableEl.addEventListener('drop', handleDrop);
}

function addDropAreaEvents(dropzoneEl) {
  //dropzoneEl.addEventListener('dragenter', null);
  dropzoneEl.addEventListener('dragover', handleDetectDropArea);
  dropzoneEl.addEventListener('drop', handleDropArea);
  dropzoneEl.addEventListener('dragleave', handleDragAreaLeave);
}


document.addEventListener('DOMContentLoaded', (event) => {
  if (typeof webui !== 'undefined') {
    // Set events callback
    webui.setEventCallback((e) => {
      if (e == webui.event.CONNECTED) {
        // Connection to the backend is established
      } else if (e == webui.event.DISCONNECTED) {
        // windows.close();
      }
    });
  }
    
  // Create Jimmy-ed content
  let viewgroup = createViewGroup();
  document.getElementById('views').appendChild(viewgroup.div);
  // viewgroup.createNewOutputView("Process1");
  // viewgroup.createNewOutputView("Process2");
  // viewgroup.createNewOutputView("Process3");
  viewgroup.setActiveTab(document.getElementsByClassName('tablinks')[0])

  // addSideBarOutputViewSection("Process1")
  // addSideBarOutputViewSection("Process2")
  // addSideBarOutputViewSection("Process3")

  // jimmy data
  // outputviews["Process1"].addToBuffer(buffer2);
  // currentLines["Process1"] = 0;
  // outputviews["Process2"] = "";
  // currentLines["Process2"] = 0;
  // outputviews["Process3"] = "";
  // currentLines["Process3"] = 0;

  // Add event listener to the button
  // nextLineButton.addEventListener("click", addLinesToProcess1);

  // Optionally, render the first line automatically
  // renderNextLine("Process1");


  let items = document.querySelectorAll('.tablinks');
  items.forEach(function(item) {
    addDraggableEvents(item);
  });

  let group = document.querySelectorAll('.output-group');
  group.forEach(function(item) {
    addDropAreaEvents(item);
  });
});

function swapNodes(n1, n2) {

    var p1 = n1.parentNode;
    var p2 = n2.parentNode;
    var i1, i2;

    if ( !p1 || !p2 || p1.isEqualNode(n2) || p2.isEqualNode(n1) ) return;

    for (var i = 0; i < p1.children.length; i++) {
        if (p1.children[i].isEqualNode(n1)) {
            i1 = i;
        }
    }
    for (var i = 0; i < p2.children.length; i++) {
        if (p2.children[i].isEqualNode(n2)) {
            i2 = i;
        }
    }

    if ( p1.isEqualNode(p2) && i1 < i2 ) {
        i2++;
    }
    p1.insertBefore(n2, p1.children[i1]);
    p2.insertBefore(n1, p2.children[i2]);
}
