#!/usr/bin/env python3
"""Guard the restored Contacts tab against the Telegram 13.2 startup deadlock."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ContactsTabStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "submodules/ContactListUI/Sources/ContactsController.swift").read_text()
        cls.source = source
        cls.initializer = source.split("public init(context: AccountContext)", 1)[1].split(
            "required public init(coder", 1
        )[0]

    def test_image_is_available_before_waiting_for_tab_readiness(self):
        # TabBarController waits for every tab's image, including unselected tabs.
        # Loading Contacts' view cannot be required to finish the initial Chats launch.
        self.assertIn("self.tabBarItem.image = tabIcon", self.initializer)
        self.assertIn("self.tabBarItem.selectedImage = tabIcon", self.initializer)
        self.assertLess(
            self.initializer.index("self.tabBarItem.image = tabIcon"),
            self.initializer.index("self.presentationDataDisposable ="),
        )
        self.assertNotIn("override public func loadDisplayNode", self.initializer)

    def test_icon_has_a_resource_and_a_system_fallback(self):
        self.assertIn('UIImage(bundleImageName: "Chat List/Tabs/IconContacts")', self.initializer)
        self.assertIn('?? UIImage(systemName: "person.crop.circle")', self.initializer)

    def test_localized_tab_presentation_updates_with_screen(self):
        self.assertIn("self.updateTabBarPresentation()", self.initializer)
        theme_update = self.source.split("private func updateThemeAndStrings()", 1)[1].split(
            "override public func loadDisplayNode", 1
        )[0]
        self.assertIn("self.updateTabBarPresentation()", theme_update)
        self.assertIn(
            "self.tabBarItem.title = self.presentationData.strings.Contacts_Title", self.source
        )
        self.assertIn('self.presentationData.reduceMotion ? nil : "TabContacts"', self.source)


if __name__ == "__main__":
    unittest.main()
