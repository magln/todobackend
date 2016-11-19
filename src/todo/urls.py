from django.conf.urls import include
from django.conf.urls import url
from django.contrib import admin
from todo import views
from rest_framework.routers import DefaultRouter

router = DefaultRouter(trailing_slash=False)
router.register(r'todos', views.TodoItemViewSet)

urlpatterns = [
  url(r'^', include(router.urls)),
]