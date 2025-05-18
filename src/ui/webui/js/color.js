function colorText(foregroundRGB, backgroundRGB, buffer, index, length) {
    let colorstr = "";
    if (foregroundRGB != null) {
      colorstr = "color:rgb("+foregroundRGB[0]+","+foregroundRGB[1]+","+foregroundRGB[2]+")";
    } 
    let backgroundstr = "";
    if (backgroundRGB != null) {
      backgroundstr = "background-color:rgb("+backgroundRGB[0]+","+backgroundRGB[1]+","+backgroundRGB[2]+")";
    }
  
    let prefix = "<span style=\""+colorstr+"; "+backgroundstr+"\")\">";
    let postfix = "</span>";
    let strInsertion = prefix + buffer.slice(index, index+length) + postfix;
    return buffer.slice(0, index) + strInsertion + buffer.slice(index+length);
  }
  
  function getLineAtIdx(buffer, idx) {
    let lineStart = buffer.lastIndexOf("\n", idx);
    if (lineStart == -1) {
      lineStart = 0;
    }
  
    let lineEnd = buffer.indexOf("\n", idx);
    if (lineEnd == -1) {
      lineEnd = buffer.length;
    }
  
    return [lineStart, lineEnd - lineStart];
  }
  
  function parseRGBStr(str) {
    if (str) {
      let strs = str.split(',');
      if (strs.length != 3)
        return null;
      return [parseInt(strs[0]), strs[1], strs[2]]
    }
    return null;
  }
  
  // a rule
  //"pattern": "\\[Error\\]",
  //"just_pattern": true,
  //"foreground_color": "220,6,6", or null
  //"background_color": "200,184,208" or null
  function colorMatches(buffer, rules) {
    let lines = buffer.split("\n");
    let newBuffer = "";
    for (let line of lines) {
      for (let rule of rules) {
        let m = line.match(rule['pattern']);
        if (m) {
          let foreground = parseRGBStr(rule['foreground_color']);
          let background = parseRGBStr(rule['background_color']);
          if (rule['just_pattern']) {
            // just color the first pattern match
            line = colorText(foreground, background, line, m.index, m[0].length);
          } else {
            // color the full line this matched on
            line = colorText(foreground, background, line, 0, line.length);
          }
        }
      }
      if (newBuffer.length == 0)
        newBuffer += line
      else   
        newBuffer += '\n'+line;
    }
    return newBuffer;
  }
  