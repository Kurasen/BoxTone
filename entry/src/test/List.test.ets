import localUnitTest from './LocalUnit.test';
import writeEngineTest from './WriteEngine.test';

export default function testsuite() {
  localUnitTest();
  writeEngineTest();
}
