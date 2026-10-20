#pragma once
#include "ProjectBrowser.h"
#include "FloatingControlTests.h"

namespace catlive::projectBrowserLoadingTests {
template <typename Test> void registerTests(const File &directory, Test &test) {
    test("Project browser cancellation stays inline and cannot cancel a later load", [&] {
        using floatingControlTests::require;
        ProjectBrowser browser;
        browser.setSize(560, 424);
        TextButton *cancel = nullptr;
        Component *status = nullptr;
        for (auto *child : browser.getChildren()) {
            if (child->getComponentID() == "cancelProjectLoading") cancel = dynamic_cast<TextButton *>(child);
            if (child->getComponentID() == "projectLoadingStatus") status = child;
        }
        require(cancel && status, "Inline loading controls are missing");
        int cancellations = 0;
        browser.beginLoading(directory.getChildFile("Import.rpp"));
        require(!cancel->isVisible() && !cancel->isEnabled(), "Ordinary project load became cancellable");
        browser.setLoadingCancellation([&] { ++cancellations; });
        require(cancel->isVisible() && cancel->isEnabled() &&
                    !cancel->getBounds().intersects(status->getBounds()),
                "Cancel is hidden, disabled or covers the loading status");
        cancel->onClick();
        cancel->onClick();
        require(cancellations == 1 && !cancel->isVisible() && browser.isLoading(),
                "Cancellation repeated or released navigation before the worker finished");
        browser.finishLoading();
        browser.beginLoading(directory.getChildFile("Next.jl"));
        cancel->onClick();
        require(cancellations == 1 && !cancel->isVisible(), "Cancellation leaked into a later load");
        browser.setLoadingCancellation([&] { ++cancellations; });
        browser.finishLoading();
        cancel->onClick();
        require(cancellations == 1 && !cancel->isVisible(), "Completion retained a cancellation action");
    });
    test("Project browser keeps progress inline, locks navigation and recovers after an open error", [&] {
        using floatingControlTests::require;
        ProjectBrowser browser;
        browser.setSize(560, 424);
        auto *recents = static_cast<ListBox *>(nullptr);
        for (auto *child : browser.getChildren())
            if (auto *list = dynamic_cast<ListBox *>(child)) recents = list;
        require(recents != nullptr, "Recent project list is missing");
        const auto rows = recents->getModel()->getNumRows();
        browser.beginLoading(directory.getChildFile("Next.jl"));
        require(browser.isLoading() && recents->isVisible() && recents->getModel()->getNumRows() == rows,
                "Loading replaced the recent list");
        require(browser.loadingMessage() == String::fromUTF8("Carregando projeto…"),
                "Loading status was not shown immediately");
        for (auto *child : browser.getChildren())
            if (dynamic_cast<Button *>(child) || dynamic_cast<TextEditor *>(child) || child == recents)
                require(!child->isEnabled(), "Navigation remained interactive while loading");
        browser.updateLoading(String::fromUTF8("Preparando waveforms… 2/5"));
        browser.beginLoading(directory.getChildFile("Repeated.jl"));
        require(browser.loadingMessage() == String::fromUTF8("Preparando waveforms… 2/5"),
                "Repeated open reset the active preparation status");
        browser.finishLoading("Invalid project");
        require(!browser.isLoading() && browser.loadingFailure() == "Invalid project" &&
                    recents->isEnabled() && recents->isVisible(),
                "Failed open did not restore the same recent list with an inline error");
        for (auto *child : browser.getChildren())
            if (dynamic_cast<Button *>(child) || dynamic_cast<TextEditor *>(child))
                require(child->isEnabled(), "Failed open left navigation disabled");
        browser.beginLoading(directory.getChildFile("Retry.jl"));
        require(browser.isLoading() && browser.loadingFailure().isEmpty(),
                "Retry retained the previous error");
        browser.finishLoading();
        require(!browser.isLoading() && browser.loadingMessage().isEmpty() &&
                    browser.loadingFailure().isEmpty(), "Successful completion retained the loading UI");
    });
}
} // namespace catlive::projectBrowserLoadingTests
