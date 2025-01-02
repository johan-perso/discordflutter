String censorString(String str) {
  if (str.length > 55) {
    return str.substring(0, 6) + '*'.padLeft(str.length - 40, '*') + str.substring(str.length - 6);
  } else if (str.length > 30) {
    return str.substring(0, 6) + '*'.padLeft(str.length - 17, '*') + str.substring(str.length - 6);
  } else if (str.length > 26){
    return str.substring(0, 6) + '*'.padLeft(str.length - 12, '*') + str.substring(str.length - 6);
  } else {
    return '*'.padLeft(str.length, '*');
  }
}