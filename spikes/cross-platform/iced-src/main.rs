// Spike: cross-platform terminal widget in Rust.
//
// QUESTION: is there a maintained, embeddable terminal widget that builds
// WITHOUT full Xcode? gpui-terminal failed — gpui shells out to the Metal
// shader compiler, which ships only with Xcode, not Command Line Tools.
// iced renders through wgpu and compiles shaders at runtime instead.
//
// BENCHMARK: the same one used on SwiftTerm — run `seq 1 200000` inside the
// terminal and let pty backpressure do the timing. A terminal that cannot
// drain output fast enough slows the process writing it.
use iced::{Element, Task};
use iced_term::{settings, Event, Terminal, TerminalView};

fn main() -> iced::Result {
    iced::application(Spike::new, Spike::update, Spike::view)
        .subscription(Spike::subscription)
        .run()
}

struct Spike {
    term: Terminal,
}

impl Spike {
    fn new() -> (Self, Task<Event>) {
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
        let cfg = settings::Settings {
            backend: settings::BackendSettings {
                program: shell,
                // -f keeps rc files out of the measurement.
                args: vec!["-f".into()],
                working_directory: Some(std::env::current_dir().unwrap()),
                ..Default::default()
            },
            font: settings::FontSettings { size: 13.0, ..Default::default() },
            ..Default::default()
        };
        let term = Terminal::new(0, cfg).expect("terminal");

        // Send the benchmark straight away — the pty buffers input until the
        // shell is ready, so no timer is needed. Timings land in a file so the
        // result can be read without screenshotting a window.
        let bench = Task::done(Event::BackendCall(
            0,
            iced_term::BackendCommand::Write(
                b"rm -f /tmp/bench-iced.txt; for n in 1 2 3; do \
/usr/bin/time -p sh -c 'seq 1 200000' 2>>/tmp/bench-iced.txt; done; echo DONE\n".to_vec()
            ),
        ));
        (Self { term }, bench)
    }

    fn update(&mut self, e: Event) -> Task<Event> {
        match e {
            Event::BackendCall(_, cmd) => {
                let _ = self.term.handle(iced_term::Command::ProxyToBackend(cmd));
            }
        }
        Task::none()
    }

    fn view(&self) -> Element<Event> {
        TerminalView::show(&self.term)
    }

    fn subscription(&self) -> iced::Subscription<Event> {
        self.term.subscription()
    }
}
