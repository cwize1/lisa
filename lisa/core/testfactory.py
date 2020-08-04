from typing import Dict
from lisa import log


class TestCaseMetadata:
    def __init__(self, method, priority, name=None):
        if name is not None:
            self.name = name
        else:
            self.name = method.__name__
        self.key = self.name.lower()
        self.full_name = method.__qualname__.lower()
        self.method = method
        self.priority = priority
        self.suite = None


class TestSuiteMetadata:
    def __init__(self, test_class, area, category, tags, name=None):
        self.test_class = test_class
        if name is not None:
            self.name = name
        else:
            self.name = test_class.__name__
        self.key = self.name.lower()
        self.area = area
        self.category = category
        self.tags = tags
        self.cases = dict()

    def addCase(self, test_case: TestCaseMetadata):
        if self.cases.get(test_case.key) is None:
            self.cases[test_case.key] = test_case
        else:
            raise Exception(
                "TestSuiteMetadata has test method %s already" % test_case.key
            )


class TestFactory:
    def __init__(self):
        self.suites: Dict[str, TestSuiteMetadata] = dict()
        self.cases: Dict[str, TestCaseMetadata] = dict()

    def addTestClass(self, test_class, area, category, tags, name):
        if name is not None:
            name = name
        else:
            name = test_class.__name__
        key = name.lower()
        test_suite = self.suites.get(key)
        if test_suite is None:
            test_suite = TestSuiteMetadata(test_class, area, category, tags)
            self.suites[key] = test_suite
        else:
            raise Exception("TestFactory duplicate test class name: %s" % key)

        class_prefix = "%s." % key
        for test_case in self.cases.values():
            if test_case.full_name.startswith(class_prefix):
                self._addCaseToSuite(test_suite, test_case)
        log.info(
            "registered test suite '%s' with test cases: '%s'",
            test_suite.key,
            ", ".join([key for key in test_suite.cases]),
        )

    def addTestMethod(self, test_method, priority):
        test_case = TestCaseMetadata(test_method, priority)
        full_name = test_case.full_name

        if self.cases.get(full_name) is None:
            self.cases[full_name] = test_case
        else:
            raise Exception("duplicate test class name: %s" % full_name)

        # this should be None in current observation.
        # the methods are loadded prior to test class
        # in case logic is changed, so keep this logic
        #   to make two collection consistent.
        class_name = full_name.split(".")[0]
        test_suite = self.suites.get(class_name)
        if test_suite is not None:
            log.debug(
                "add case '%s' to suite '%s'", test_case.name, test_suite.name
            )
            self._addCaseToSuite(test_suite, test_case)

    def _addCaseToSuite(
        self, test_suite: TestSuiteMetadata, test_case: TestCaseMetadata
    ):
        test_suite.addCase(test_case)
        test_case.suite = test_suite


testFactory = TestFactory()