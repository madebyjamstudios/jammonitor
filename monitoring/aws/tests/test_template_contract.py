import re
import unittest
from pathlib import Path


TEMPLATE = (Path(__file__).parents[1] / "template.yaml").read_text(
    encoding="utf-8"
)


class TemplateContractTests(unittest.TestCase):
    def test_notification_email_is_required(self):
        parameter = re.search(
            r"(?ms)^  NotificationEmail:\n(?P<body>.*?)(?=^  [A-Za-z].*:\n)",
            TEMPLATE,
        )
        self.assertIsNotNone(parameter)
        body = parameter.group("body")
        self.assertNotIn("Default:", body)
        self.assertIn("MinLength:", body)
        self.assertNotIn("^$|", body)

    def test_email_subscription_is_unconditional(self):
        subscription = re.search(
            r"(?ms)^  AlertEmailSubscription:\n(?P<body>.*?)(?=^  [A-Za-z].*:\n)",
            TEMPLATE,
        )
        self.assertIsNotNone(subscription)
        body = subscription.group("body")
        self.assertNotIn("Condition:", body)
        self.assertIn("Endpoint: !Ref NotificationEmail", body)

    def test_log_group_arn_is_not_double_wildcarded(self):
        self.assertIn("Resource: !GetAtt MonitorLogGroup.Arn", TEMPLATE)
        self.assertNotIn("${MonitorLogGroup.Arn}:*", TEMPLATE)


if __name__ == "__main__":
    unittest.main()
