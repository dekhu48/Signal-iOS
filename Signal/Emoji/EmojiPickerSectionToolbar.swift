//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol EmojiPickerSectionToolbarDelegate: AnyObject {
    func emojiPickerSectionToolbar(_ sectionToolbar: EmojiPickerSectionToolbar, didSelectSection: Int)
    func emojiPickerSectionToolbarShouldShowRecentsSection(_ sectionToolbar: EmojiPickerSectionToolbar) -> Bool
}

class EmojiPickerSectionToolbar: BlurredToolbarContainer {
    private var buttons = [UIButton]()

    private weak var delegate: EmojiPickerSectionToolbarDelegate?

    init(
        delegate: EmojiPickerSectionToolbarDelegate,
        forceDarkTheme: Bool = false
    ) {
        self.delegate = delegate

        super.init(forceDarkTheme: forceDarkTheme)

        buttons = [
            createSectionButton(icon: .emojiSmiley),
            createSectionButton(icon: .emojiAnimal),
            createSectionButton(icon: .emojiFood),
            createSectionButton(icon: .emojiActivity),
            createSectionButton(icon: .emojiTravel),
            createSectionButton(icon: .emojiObject),
            createSectionButton(icon: .emojiSymbol),
            createSectionButton(icon: .emojiFlag)
        ]

        if delegate.emojiPickerSectionToolbarShouldShowRecentsSection(self) == true {
            buttons.insert(createSectionButton(icon: .emojiRecent), at: 0)
        }

        toolbar.items = Array(
            buttons
                .map { [UIBarButtonItem(customView: $0)] }
                .joined(separator: [.flexibleSpace()])
        )

        setSelectedSection(0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func createSectionButton(icon: ThemeIcon) -> UIButton {
        let button = UIButton()
        button.setImage(Theme.iconImage(icon), for: .normal)

        let selectedBackgroundColor: UIColor
        if UIAccessibility.isReduceTransparencyEnabled {
            selectedBackgroundColor = (Theme.isDarkThemeEnabled || forceDarkTheme) ? UIColor.ows_gray75 : UIColor.ows_gray05
        } else {
            selectedBackgroundColor = forceDarkTheme ? Theme.darkThemeBackgroundColor : Theme.backgroundColor
        }

        button.setBackgroundImage(UIImage.image(color: selectedBackgroundColor), for: .selected)

        button.autoSetDimensions(to: CGSize(square: 30))
        button.layer.cornerRadius = 15
        button.clipsToBounds = true

        button.addTarget(self, action: #selector(didSelectSection), for: .touchUpInside)

        return button
    }

    @objc
    private func didSelectSection(sender: UIButton) {
        guard let selectedSection = buttons.firstIndex(of: sender) else {
            return owsFailDebug("Selectetd unexpected button")
        }

        setSelectedSection(selectedSection)

        delegate?.emojiPickerSectionToolbar(self, didSelectSection: selectedSection)
    }

    func setSelectedSection(_ section: Int) {
        buttons.forEach { $0.isSelected = false }
        buttons[safe: section]?.isSelected = true
    }
}
