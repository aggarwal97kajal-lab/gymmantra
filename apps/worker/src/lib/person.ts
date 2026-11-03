import { isYmd, todayIST } from './dates';
import { bad } from './http';
import { pinMatchesState, stateByName } from './india';
import { oneOf, optStr, str } from './validate';

export interface PersonDetails {
  firstName: string;
  middleName: string | null;
  lastName: string;
  name: string;
  dob: string;
  gender: 'male' | 'female' | 'other' | null;
  state: string;
  city: string;
  country: string;
  pincode: string;
}

/**
 * The same details everywhere: sign-up (member, trainer, owner) and "Add member".
 * First and last name, date of birth, state, city, country, PIN.
 */
export function personDetails(b: Record<string, unknown>): PersonDetails {
  const firstName = str(b, 'firstName', { min: 1, max: 40, label: 'the first name' }).trim();
  const middleName = (optStr(b, 'middleName', { max: 40 }) ?? '').trim() || null;
  const lastName = str(b, 'lastName', { min: 1, max: 40, label: 'the last name' }).trim();
  const name = [firstName, middleName, lastName].filter(Boolean).join(' ');
  const dob = str(b, 'dob', { label: 'the date of birth' });
  if (!isYmd(dob) || dob > todayIST() || dob < '1900-01-01') throw bad('Date of birth is not valid');
  const gender = oneOf(b, 'gender', ['male', 'female', 'other'] as const, true) ?? null;
  const country = (optStr(b, 'country', { max: 60 }) ?? 'India').trim() || 'India';
  const stateIn = str(b, 'state', { max: 60, label: 'the state' }).trim();
  const city = str(b, 'city', { min: 2, max: 60, label: 'the city' }).trim();
  const pincode = str(b, 'pincode', { label: 'the PIN code' }).replace(/\s/g, '');
  let state = stateIn;
  if (country.toLowerCase() === 'india') {
    const st = stateByName(stateIn);
    if (!st) throw bad('Choose a state from the list');
    state = st.name;
    if (!/^[1-9]\d{5}$/.test(pincode)) throw bad('Enter a valid 6-digit PIN code');
    if (!pinMatchesState(pincode, state)) throw bad(`This PIN code is not from ${state}. Check the PIN or the state`);
  } else if (!/^[A-Za-z0-9 -]{3,10}$/.test(pincode)) throw bad('Enter a valid PIN code');
  return { firstName, middleName, lastName, name, dob, gender, state, city, country, pincode };
}

/** Did the request send the full details? (Older app versions send only the name.) */
export const hasDetails = (b: Record<string, unknown>) => b.firstName !== undefined;
