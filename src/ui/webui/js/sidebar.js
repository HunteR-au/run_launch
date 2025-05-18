g_globalColorRules = new Map();

/* Set the width of the side navigation to 250px */
function openNav() {
    document.getElementById("mySidenav").style.width = "500px";
}

/* Set the width of the side navigation to 0 */
function closeNav() {
    document.getElementById("mySidenav").style.width = "0";
}

let ruleTextBoxCount = 0;
function createRuleTextBoxEl() {
    let count = ruleTextBoxCount;  
    ruleTextBoxCount = ruleTextBoxCount + 1;
    const viewgroupdivId = 'rule-textbox-' + count;

    let ruleTextBox = document.createElement('textarea');
    ruleTextBox.className = 'rule-textbox';
    ruleTextBox.id = viewgroupdivId;
    ruleTextBox.style.height="90px";

    const defaulttext = 
`{
    "pattern":"",
    "foreground_color":"0,0,0",
    "just_pattern":false
}`

    ruleTextBox.value = defaulttext;

    addEventRulesTextBoxChanged(ruleTextBox);

    return ruleTextBox
}

function addSideBarOutputViewSection(processName) {
    const sideBarRuleGroup = document.getElementsByClassName("sidebar-rule-list")
    const lastSideBarRuleGroup = sideBarRuleGroup[sideBarRuleGroup.length-1];

    let ruleListDiv = document.createElement('div')
    ruleListDiv.className = "sidebar-rule-list"
    ruleListDiv.id = "sidebar-rule-" + processName

    let header = document.createElement('a')
    header.h2 = "#";
    header.innerText = processName + " Rules"
    ruleListDiv.appendChild(header);

    let ruleBoxContainer = document.createElement('div')
    ruleBoxContainer.className = "text-boxes-container"
    ruleListDiv.appendChild(ruleBoxContainer);

    let addLink = document.createElement('a')
    addLink.className = "addRulebtn"
    addLink.onclick = function() {addSideBarRuleBox(processName)}
    addLink.innerText = "+ add rule"
    addLink.href = "#"
    ruleListDiv.appendChild(addLink);

    lastSideBarRuleGroup.insertAdjacentElement('afterend', ruleListDiv)

    preloadSideBarFromUiConfig(uiConfig, processName);
}

function addSideBarRuleBox(processName) {
    let ruleListDiv = null
    if (processName == "rule-list-global") {
        // add to the global rule set
        ruleListDiv = document.getElementById("rule-list-global")
        
    } else {
        ruleListDiv = document.getElementById("sidebar-rule-"+processName)
    }
    
    const textBoxContainer = ruleListDiv.getElementsByClassName("text-boxes-container")[0]
    const el = createRuleTextBoxEl();
    textBoxContainer.insertAdjacentElement('beforeend', el)
    el.insertAdjacentHTML('afterend', '<a class="delete-rule-box" onclick="removeSideBarRuleBox(\''+el.id+'\')">delete</a>')
    return el;
}

function getProcessNameFromRuleTextBox(textBox) {
    const ruleGroupParentId = textBox.parentElement.parentElement.id
    const idStringPrefix = "sidebar-rule-";

    if (ruleGroupParentId == "rule-list-global") {
        // the global rules list
        return "rule-list-global"
    } else {
        if (!ruleGroupParentId.startsWith(idStringPrefix)) {
            throw Error("Prefix of ruleGroup div is unexpected")
        }
        return ruleGroupParentId.substring(idStringPrefix.length);
    }
}

function removeSideBarRuleBox(ruleTextBoxId) {
    let el = document.getElementById(ruleTextBoxId);

    let found = false
    let children = el.parentElement.children
    for (let childIdx in children) {
        if (children[childIdx].id = ruleTextBoxId) {
            let processName = getProcessNameFromRuleTextBox(children[childIdx]);

            if (processName == "rule-list-global") {
                // delete from the global list
                g_globalColorRules.delete(children[childIdx].id);

                // render the changes
                renderAllActiveOutputs();
            } else {
                outputviews[processName].removeFormattingRule(ruleTextBoxId);
                renderOutputIfActive(processName);
            }
            
            children[childIdx].remove();
            found = true
        }
        if (found) {
            // delete the element below the textbox
            children[childIdx].remove();
            break
        }
    }
}

function validateColorRule(rule) {
    if (!rule.hasOwnProperty('pattern')) {
        return false;
    }
    if (typeof rule['pattern'] != 'string') {
        return false;
    }

    if (!(rule.hasOwnProperty('foreground_color') || rule.hasOwnProperty('background_color'))) {
        return false;
    }
    
    if (rule.hasOwnProperty('foreground_color')) {
        if (typeof rule['foreground_color'] != 'string') {
            return false;
        }
        if (!rule['foreground_color'].match("^\\d+,\\d+,\\d+$")) {
            return false;
        }
    }

    if (rule.hasOwnProperty('background_color')) {
        if (typeof rule['background_color'] != 'string') {
            return false;
        }
        if (!rule['background_color'].match("^\\d+,\\d+,\\d+$")) {
            return false;
        }
    }

    // optionals
    if (rule.hasOwnProperty('just_pattern')) {
        if (typeof rule['just_pattern'] != "boolean") {
            return false;
        }
    }

    return true;
}

function addColorRulesToProcessConfig(processName, colorRules) {
    function removeNullValues(key, value) {
      return value === null ? undefined : value;
    }    
    
    for (var i = 0; i < colorRules.length; ++i) {
        let jsonStr = JSON.stringify(colorRules[i], removeNullValues, 2)
        let textBoxEl = addSideBarRuleBox(processName)
        // update the text box
        textBoxEl.value = jsonStr;

        // update the render with the json written to the
        // textbox
        console.log(textBoxEl.id)
        console.log(processName)
        console.log(colorRules[i])
        applyColorRuleToViewAndRender(
            textBoxEl.id,
            processName,
            colorRules[i])
    }
}

// If ProcessName is null then preload all existing processes
function preloadSideBarFromUiConfig(uiConfig, processToUpdate) {
    function findMatches(targetString, stringArray) {
        const results = [];
        for (const str of stringArray) {
            if (str.includes(targetString)) {
                results.push(str);
            }
        }
        return results;
    }
    if (uiConfig == null) {
        return;
    }

    let processes = null
    if (processToUpdate == null) {
        processes = listAllOutputViewProcessNames()
        processes.push('GLOBAL')
        console.log(processes)
    } else {
        processes = [processToUpdate]
    }      

    for (var i = 0; i < uiConfig.processes.length; ++i) {
        let matches = findMatches(uiConfig.processes[i].processName, processes)
        for (var j = 0; j < matches.length; ++j) {
            if (matches[j] == 'GLOBAL') {
                addColorRulesToProcessConfig("rule-list-global", uiConfig.processes[i].colorRules)
            } else {
                addColorRulesToProcessConfig(matches[j], uiConfig.processes[i].colorRules)
            }
        }
    }
}

function applyColorRuleToViewAndRender(textBoxId, processName, rule) {
    console.log("apply color for process:" + processName)
    if (processName == "rule-list-global") {
        g_globalColorRules.set(textBoxId, rule);
        renderAllActiveOutputs();
    } else {
        outputviews[processName].addFormattingRule(textBoxId, rule);
        renderOutputIfActive(processName);
    }
}

//"pattern": "\\[Error\\]",
//"just_pattern": true,
//"foreground_color": "220,6,6", or null
//"background_color": "200,184,208" or null
function addEventRulesTextBoxChanged(textbox) {
    textbox.addEventListener('input', function(e) {
        let rule = null;
        // parse json rules
        try {
            rule = JSON.parse(this.value)
        } catch (error) {
            if (g_globalColorRules.has(this.id)) {
                g_globalColorRules.delete(this.id);
                renderAllActiveOutputs();
            }
            this.style.borderColor = 'crimson';
            return
        }

        const isRuleValid = validateColorRule(rule)
        if (isRuleValid) {
            let processName = getProcessNameFromRuleTextBox(this);
            
            applyColorRuleToViewAndRender(this.id, processName, rule);

            // add valid style
            this.style.borderColor = '';
        } else {
            if (g_globalColorRules.has(this.id)) {
                // The rule is invalid, remove it from the global map
                g_globalColorRules.delete(this.id);
                renderAllActiveOutputs();
            }
            // add invalid style 
            this.style.borderColor = 'crimson';
        }
    });
}
