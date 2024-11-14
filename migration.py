import mailbox
from pathlib import Path

from tqdm import tqdm
import typer


app = typer.Typer()


@app.command()
def migrate(
    src: Path = typer.Argument(..., help="Path to a mailbox in maildir format"),
    dst: Path = typer.Argument(..., help="Path to a mailbox in mbox format"),
):
    M = mailbox.Maildir(src)
    dst = mailbox.mbox(dst)

    dst.lock()
    
    for message in tqdm(M):
        dst.add(mailbox.mboxMessage(message))

    dst.flush()
    dst.unlock()


if __name__ == "__main__":
    app()
