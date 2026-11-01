module.exports = {
  testEnvironment: 'node',
  testRegex: 'test/.*\\.test\\.ts$',
  transform: { '^.+\\.ts$': ['ts-jest', { isolatedModules: true, tsconfig: { module: 'commonjs', target: 'ES2022', esModuleInterop: true, resolveJsonModule: true } }] },
  transformIgnorePatterns: [],
  testTimeout: 30000,
};
