

def test_py():
    from tcp_ping.compute import python_add

    assert python_add(2, 3) == 5


if __name__ == "__main__":

    test_py()
