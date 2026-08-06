/// 常见弱密码列表（中英常见项），用于解锁页非阻断警告提示。
///
/// 仅用于提示风险，不阻断用户设置/解锁；命中集合或长度 < 6 视为弱密码。
const Set<String> weakPasswords = {
  // 纯数字
  '123', '1234', '12345', '123456', '1234567', '12345678', '123456789',
  '1234567890', '111111', '222222', '333333', '444444', '555555', '666666',
  '777777', '888888', '999999', '000000', '5201314', '1314520',
  // 常见英文弱密码
  'password', 'passw0rd', 'password1', 'password123', 'qwerty', 'qwerty123',
  'abc123', 'abc1234', 'admin', 'administrator', 'root', 'welcome',
  'welcome1', 'iloveyou', 'monkey', 'dragon', 'master', 'shadow', 'sunshine',
  'princess', 'football', 'baseball', 'letmein', 'trustno1', 'superman',
  'batman', 'charlie', 'michael', 'jordan', 'cookie', 'flower', 'soccer',
  // 键盘序列
  '1q2w3e4r', '1qaz2wsx', 'qazwsx', 'zxcvbnm', 'asdfgh', 'asdfghjkl',
  'zaq12wsx', 'qwertyuiop', 'poiuytrewq',
  // 中文常见弱密码
  'woaini', 'aini1314', 'woaini1314', 'a123456', 'abcabc', '123abc',
  'wang123', 'zhang123',
};

/// 弱密码判定：命中常见弱密码集合（大小写不敏感）或长度 < 6。
bool isWeakPassword(String password) {
  if (password.length < 6) return true;
  return weakPasswords.contains(password.toLowerCase());
}
