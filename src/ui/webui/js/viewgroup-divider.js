// TODO: change divider to div
function newGroupDivider() {
    var newDivider = document.createElement('div');
    newDivider.className = 'viewgroup-divider'
    newDivider.style = '0 auto; opacity: 0; color: cornflowerblue';
    newDivider.style.borderStyle = "solid";
    newDivider.style.backgroundColor = 'cornflowerblue';
    newDivider.style.marginTop = '30px';
    newDivider.style.marginBottom = '30px';
    newDivider.style.marginLeft = "10px";
    newDivider.style.marginRight = "10px";
    newDivider.width = "12px";
    newDivider.height = "90pv";
    addViewGroupDividerEvents(newDivider);
    return newDivider;
}

function addNumberToPercentage(percentageString, numberToAdd) {
    const percentage = parseFloat(percentageString);
    if (isNaN(percentage)) {
      return "Invalid percentage string";
    }
    const result = percentage + numberToAdd;
    return result + "%";
}

function removeNumberToPercentage(percentageString, numberToAdd) {
    // console.log(percentageString)
    const percentage = parseFloat(percentageString);
    if (isNaN(percentage)) {
      return "Invalid percentage string";
    }
    const result = percentage - numberToAdd;
    return result + "%";
}

function growShrinkViewGroupPair(sourceGroupDiv, destGroupDiv, percent) {
    if (sourceGroupDiv == null || destGroupDiv == null) {
        throw "Source/Dest Group div cannot be null"
    }
    // TODO - validate input to make sure bounds (0,100) stay valid
    if (sourceGroupDiv.style.flexBasis == "") {
        const computedStyle = window.getComputedStyle(sourceGroupDiv);
        // console.log(computedStyle.getPropertyValue('flex-basis'));
        sourceGroupDiv.style.flexBasis = computedStyle.getPropertyValue('flex-basis');
    }
    if (destGroupDiv.style.flexBasis == "") {
        const computedStyle = window.getComputedStyle(destGroupDiv);
        // console.log(computedStyle.getPropertyValue('flex-basis'));
        destGroupDiv.style.flexBasis = computedStyle.getPropertyValue('flex-basis');
    }
        
    let newPercent = removeNumberToPercentage(sourceGroupDiv.style.flexBasis.replace('%', ''), percent)
    sourceGroupDiv.style.flexBasis = newPercent; 

    // console.log("new percentage: " + newPercent);
    // console.log("new percentage: " + sourceGroupDiv.style.flexBasis);

    newPercent = addNumberToPercentage(destGroupDiv.style.flexBasis.replace('%', ''), percent)
    destGroupDiv.style.flexBasis = newPercent;
}

function getOffset(el) {
    const rect = el.getBoundingClientRect();
    return {
        left: rect.left + window.scrollX,
        top: rect.top + window.scrollY
    };
}

function getMouseToHRDistanceAsPercentage(mousePosX, hrDiv) {
    const viewsDivWidth = document.getElementById("views").width;
    const hrPosX = getOffset(hrDiv);
    // console.log(hrPosX);

    // var x = e.pageX - outputViewDiv.offsetLeft;
    // var y = e.pageY - outputViewDiv.offsetTop;
}
// async function poll(fn, fnCondition, ms) {
//     let result = await fn();
//     while (fnCondition(result)) {
//         await wait(ms);
//         result = await fn();
//     }
//     return result;
// }
  
// function wait(ms = 100) {
// return new Promise(resolve => {
//     console.log(`waiting ${ms} ms...`);
//     setTimeout(resolve, ms);
// });
// }

// function getOffset(el) {
//     const rect = el.getBoundingClientRect();
//     return {
//         left: rect.left + window.scrollX,
//         top: rect.top + window.scrollY
//     };
// }

// let mousePosX = null;
// let mousePosY = null;
// function handleDividerDragStart(e) {
//     let leftDiv = e.target.previousElementSibling;
//     let rightDiv = e.target.nextElementSibling;

//     const viewsDivWidth = document.getElementById("views").width;
    
//     e.target.addEventListener("mousemove", (e) => {
//         mousePosX = e.pageX;
//         mousePosY = e.pageY;
//     });

//     //updateViewGroupGrowFactor
//     let l = () => {
//         // check if mouse is left/right of hr
//         if (mousePosX != null && mousePosY != null) {
//             // TODO: get X1/X2 for the hr
//             const posX = getOffset(e.target).left - mousePosX;

//             if (posX < 0) {
//                 // mouse is left
//                 const widthPercentOfViewPort = (posX * -1) / viewsDivWidth * 100;

//             }
//             else if (posX > 0) {
//                 // mouse is right
//                 const widthPercentOfViewPort = posX / viewsDivWidth * 100;
//             }
//             else {
//                 // mouse of hr
//                 return true;
//             }
            
//             // find the diff between mouse and hr as a % of views view width


//             if (mousePosX < posX) {

//             } else if (mousePosX > pos.left) {

//             }

//             return true;
//         } else {
//             return false;
//         }
//     };

//     let m = (val) => {return val};

//     // TODO: probably need to create a poll function
//     poll(l, m, 100);
// }

var isDragging = false;
function adjustViewGroupsWidth(e) {
    if (typeof e.target.classList === 'undefined') {
        return;
    }
    if (!e.target.classList.contains("viewgroup-divider")) {
        return;
    }
    const mousePosX = e.pageX;
    const mousePosY = e.pageY;

    // The X/Y coords of the views div
    const viewsDiv = document.getElementById("views");
    var x = e.pageX - viewsDiv.offsetLeft;
    var y = e.pageY - viewsDiv.offsetTop;

    // Get mouse x coord as a percentage
    var xWidthPercent = (x*100) / viewsDiv.clientWidth;

    // Get hr x coord as a percentage
    let dictRect = e.target.getBoundingClientRect();
    let viewsRect = viewsDiv.getBoundingClientRect();
    let hrXWidthPercent = (dictRect.left - viewsRect.left)*100 / viewsDiv.clientWidth; 

    let leftDiv = e.target.previousElementSibling;
    let rightDiv = e.target.nextElementSibling;

    let hrXWidthPercentInt = parseInt(hrXWidthPercent)
    let xWidthPercentInt = parseInt(xWidthPercent)
    if (hrXWidthPercentInt > xWidthPercentInt) {
        growShrinkViewGroupPair(leftDiv, rightDiv, 1);
    } else if (hrXWidthPercentInt < xWidthPercentInt) {
        growShrinkViewGroupPair(rightDiv, leftDiv, 1);
    }
}

function handleDividerDragStart(e) {
    let leftDiv = e.target.previousElementSibling;
    let rightDiv = e.target.nextElementSibling;

    const viewsDiv = document.getElementById("views");
    const viewsDivWidth = viewsDiv.width;
    // console.log("Starting hr dragging")
    isDragging = true;
}    

function handleDividerDragEnd(e) {
    // console.log("DRAG ENG");
    isDragging = false;
}

function addViewGroupDividerEvents(dividerEl) {
    // TODO: change flex weightings of the divs either side
    dividerEl.addEventListener("mouseover", (e) => {
        e.target.style.color = "cornflowerblue";
        e.target.style.outline_color = "cornflowerblue";
        e.target.style.opacity = 1;
        e.target.style.display = "block";
    });
    dividerEl.addEventListener("mouseout", (e) => {
        e.target.style.opacity = 0;
    });
    dividerEl.addEventListener('dragstart', handleDividerDragStart);
    dividerEl.addEventListener('dragend', handleDividerDragEnd);
    document.addEventListener('drag', adjustViewGroupsWidth);
}

