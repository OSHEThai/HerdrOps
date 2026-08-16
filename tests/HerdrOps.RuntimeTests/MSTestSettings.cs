// WPF views and UiLanguageService.Shared are process-wide dispatcher state.
// Serialize the complete RuntimeTests assembly so no other test class can
// mutate the language catalog while a view is being measured or rendered.
[assembly: DoNotParallelize]
