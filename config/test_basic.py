@m.package(
    name="basic",
    version=lambda pkg: "1.0",
    tags=["tag1", "tag2"]
)
def basic(pkg):
    print("Hello World")

@m.package(
    name="basic1",
    version="1.0",
)
def basic1(pkg):
    print("Hello World")
