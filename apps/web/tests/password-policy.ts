import {
  MIN_PASSWORD_LENGTH,
  passwordPolicyError,
} from "../lib/auth/password-policy";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

assert(MIN_PASSWORD_LENGTH === 12, "R1 password minimum must remain 12");

assert(
  passwordPolicyError("sign-up/email", { password: "shortpass" }) !== null,
  "sign-up must reject passwords shorter than 12",
);

assert(
  passwordPolicyError("reset-password", { newPassword: "shortpass" }) !== null,
  "password reset must reject passwords shorter than 12",
);

assert(
  passwordPolicyError("change-password", { newPassword: "shortpass" }) !== null,
  "password change must reject passwords shorter than 12",
);

assert(
  passwordPolicyError("reset-password", { newPassword: "long-passphrase" }) === null,
  "password reset must accept 12+ character passphrases",
);

assert(
  passwordPolicyError("sign-in/email", { password: "shortpass" }) === null,
  "sign-in must not reject an existing account solely because its historic password is shorter",
);

console.log("password policy: all checks passed");
