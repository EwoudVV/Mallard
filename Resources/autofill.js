(payload => {
  if (location.origin !== payload.origin) return { filled: 0, reason: 'origin-changed' };
  const record = payload.record;
  const visible = element => element && !element.disabled && !element.readOnly && element.type !== 'hidden' && element.getClientRects().length > 0 && getComputedStyle(element).visibility !== 'hidden';
  let filled = 0;
  const put = (element, value) => {
    if (!visible(element)) return;
    const prototype = element instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    filled++;
  };
  const find = selector => Array.from(document.querySelectorAll(selector)).find(visible);
  if (record.kind === 'password') {
    const password = find('input[type=password]');
    if (!password) return { filled: 0, reason: 'no-password-field' };
    const scope = password.form || document;
    const username = Array.from(scope.querySelectorAll('input[autocomplete=username],input[type=email],input[name*=email i],input[name*=user i]')).find(visible);
    put(username, record.username);
    put(password, record.password);
  } else if (record.kind === 'card') {
    put(find('[autocomplete=cc-name]'), record.name);
    put(find('input[autocomplete=cc-number]'), record.number);
    put(find('[autocomplete=cc-exp-month]'), record.month);
    put(find('[autocomplete=cc-exp-year]'), record.year);
    put(find('input[autocomplete=cc-exp]'), record.month + '/' + record.year.slice(-2));
  }
  return { filled, reason: filled ? 'filled' : 'no-supported-fields' };
})
