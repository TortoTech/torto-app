use rebook_publication::{Block, Inline, TextBlock};

fn text(block: &TextBlock, spine: usize, output: &mut String) {
    let Some(range) = &block.source else { return; };
    let content: String = block.content.iter().map(|item| match item {
        Inline::Text(run) => run.text.clone(),
        Inline::Break => "\n".into(),
        _ => String::new(),
    }).collect();
    let hex: String = content.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect();
    output.push_str(&format!("{spine}\t{}\t{}\t{hex}\t{:?}\n", range.start.spine.as_str(), range.start.node, block.kind));
}
fn visit(block: &Block, spine: usize, output: &mut String) {
    match block {
        Block::Text(b) => text(b, spine, output),
        Block::Quote(q) => {
            for b in &q.body { text(b, spine, output); }
            if let Some(b) = &q.attribution { text(b, spine, output); }
        }
        Block::Table(t) => for row in &t.rows { for cell in &row.cells { text(&cell.text, spine, output); } },
        Block::Figure(f) => for b in &f.captions { text(b, spine, output); },
        Block::Note(n) => for b in &n.blocks { visit(b, spine, output); },
        Block::Separator(s) => if let Some(b) = &s.text { text(b, spine, output); },
        _ => (),
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args[1] == "--html" {
        let descriptor = rebook_publication::SpineItem {
            id: rebook_publication::SpineItemId::new("chapter")?,
            href: rebook_publication::PublicationUrl::parse("chapter.xhtml")?,
            media_type: "application/xhtml+xml".into(), linear: true, properties: Vec::new(),
        };
        let section = rebook_html::parse_section(&std::fs::read_to_string(&args[2])?, &descriptor, |_| None)?;
        let mut output = String::new();
        for block in &section.blocks { visit(block, 0, &mut output); }
        std::fs::write(&args[3], output)?;
        return Ok(());
    }
    let book = rebook_formats::open_file(&args[1])?;
    let source = book.source();
    let mut output = String::new();
    for i in 0..book.book().sections.len() {
        let section = source.parse_section(i)?;
        for block in &section.blocks { visit(block, i, &mut output); }
    }
    std::fs::write(&args[2], output)?;
    Ok(())
}
