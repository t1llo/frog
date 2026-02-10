package main

import (
	"embed"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/menu/keys"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"
	wailsruntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := NewApp()

	// Build the application menu
	appMenu := menu.NewMenu()

	// Frog menu
	frogMenu := appMenu.AddSubmenu("Frog")
	frogMenu.AddText("About Frog", nil, func(_ *menu.CallbackData) {
		wailsruntime.MessageDialog(app.ctx, wailsruntime.MessageDialogOptions{
			Type:    wailsruntime.InfoDialog,
			Title:   "About Frog",
			Message: "Frog - Quick Text Correction & Translation\nVersion 0.1.0",
		})
	})
	frogMenu.AddSeparator()
	frogMenu.AddText("Quit", keys.CmdOrCtrl("q"), func(_ *menu.CallbackData) {
		wailsruntime.Quit(app.ctx)
	})

	// Text menu with shortcuts
	textMenu := appMenu.AddSubmenu("Text")
	textMenu.AddText("Correct Text", keys.CmdOrCtrl("1"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:correct")
	})
	textMenu.AddText("Correct Email", keys.CmdOrCtrl("2"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:email")
	})
	textMenu.AddText("Create Outline", keys.CmdOrCtrl("3"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:outline")
	})
	textMenu.AddText("Summarize", keys.CmdOrCtrl("4"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:summarize")
	})
	textMenu.AddText("Translate", keys.CmdOrCtrl("5"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:translate")
	})
	textMenu.AddSeparator()
	textMenu.AddText("Paste from Clipboard", keys.CmdOrCtrl("shift+v"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "action:paste-clipboard")
	})

	// Edit menu (standard macOS)
	editMenu := appMenu.AddSubmenu("Edit")
	editMenu.AddText("Cut", keys.CmdOrCtrl("x"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "edit:cut")
	})
	editMenu.AddText("Copy", keys.CmdOrCtrl("c"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "edit:copy")
	})
	editMenu.AddText("Paste", keys.CmdOrCtrl("v"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "edit:paste")
	})
	editMenu.AddText("Select All", keys.CmdOrCtrl("a"), func(_ *menu.CallbackData) {
		wailsruntime.EventsEmit(app.ctx, "edit:selectAll")
	})

	// Run the application
	err := wails.Run(&options.App{
		Title:     "Frog",
		Width:     900,
		Height:    600,
		MinWidth:  700,
		MinHeight: 500,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		Menu:             appMenu,
		BackgroundColour: &options.RGBA{R: 15, G: 17, B: 23, A: 255},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		OnBeforeClose:    app.beforeClose,
		Bind: []interface{}{
			app,
		},
		Mac: &mac.Options{
			TitleBar: &mac.TitleBar{
				TitlebarAppearsTransparent: true,
				HideTitle:                  true,
				HideTitleBar:               false,
				FullSizeContent:            true,
				UseToolbar:                 true,
				HideToolbarSeparator:       true,
			},
			About: &mac.AboutInfo{
				Title:   "Frog",
				Message: "Quick Text Correction & Translation\nVersion 0.1.0",
			},
			WebviewIsTransparent: false,
			WindowIsTranslucent:  true,
			Appearance:           mac.NSAppearanceNameDarkAqua,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
