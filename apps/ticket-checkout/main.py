from fastapi import FastAPI

app = FastAPI(title="ticket-checkout")


@app.post("/checkout")
def checkout():
    return {"status": "success"}
