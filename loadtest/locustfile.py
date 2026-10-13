"""Traffic generator for the Auto Scaling test.

Web UI (live charts, good for screenshots):
    uvx locust -f loadtest/locustfile.py --host http://<alb-dns-name>
Headless, with an HTML report:
    uvx locust -f loadtest/locustfile.py --host http://<alb-dns-name> --headless \
        -u 100 -r 2 -t 10m --html loadtest/report.html
"""
from locust import HttpUser, between, task


class LibraryUser(HttpUser):
    wait_time = between(0.1, 0.4)

    @task(6)
    def books(self):
        self.client.get("/api/books")

    @task(3)
    def stress(self):
        # CPU-heavy request so average CPU actually rises above the scaling target.
        self.client.get("/api/stress?ms=300", name="/api/stress")

    @task(1)
    def loans(self):
        self.client.get("/api/loans")
