// page loader //

function hideLoader() {
  const loader = document.getElementById("loader");
  loader.classList.add("d-none");
}
window.addEventListener("load", hideLoader);

// page loader //

// cover-image //
var coverImg = document.querySelectorAll(".cover-image");

coverImg.forEach((ele) => {
  var attr = ele.getAttribute("data-bs-image-src");
  if (attr && typeof attr !== typeof undefined && attr !== false) {
    ele.style.background = `url(${attr}) center center`;
  }
});
// cover-image //

//switcher color pickers
const pickrContainerPrimary = document.querySelector(
  ".pickr-container-primary"
);
const themeContainerPrimary = document.querySelector(
  ".theme-container-primary"
);
const pickrContainerBackground = document.querySelector(
  ".pickr-container-background"
);
const themeContainerBackground = document.querySelector(
  ".theme-container-background"
);

// for theme primary //
const nanoThemes = [
  [
    "nano",
    {
      defaultRepresentation: "RGB",
      components: {
        preview: true,
        opacity: false,
        hue: true,

        interaction: {
          hex: false,
          rgba: true,
          hsva: false,
          input: true,
          clear: false,
          save: false,
        },
      },
    },
  ],
];
const nanoButtons = [];
let nanoPickr = null;
for (const [theme, config] of nanoThemes) {
  const button = document.createElement("button");
  button.innerHTML = theme;
  nanoButtons.push(button);

  button.addEventListener("click", () => {
    const el = document.createElement("p");
    pickrContainerPrimary.appendChild(el);

    /* Delete previous instance */
    if (nanoPickr) {
      nanoPickr.destroyAndRemove();
    }

    /* Apply active class */
    for (const btn of nanoButtons) {
      btn.classList[btn === button ? "add" : "remove"]("active");
    }

    /* Create fresh instance */
    nanoPickr = new Pickr(
      Object.assign(
        {
          el,
          theme,
          default: "#845adf",
        },
        config
      )
    );

    /* Set events */
    nanoPickr.on("changestop", (source, instance) => {
      let color = instance.getColor().toRGBA();
      let html = document.querySelector("html");
      html.style.setProperty(
        "--primary-rgb",
        `${Math.floor(color[0])}, ${Math.floor(color[1])}, ${Math.floor(
          color[2]
        )}`
      );
      /* theme color picker */
      localStorage.setItem(
        "primaryRGB",
        `${Math.floor(color[0])}, ${Math.floor(color[1])}, ${Math.floor(
          color[2]
        )}`
      );
      updateColors();
    });
  });

  themeContainerPrimary.appendChild(button);
}
nanoButtons[0].click();
// for theme primary //

// for theme background //
const nanoThemes1 = [
  [
    "nano",
    {
      defaultRepresentation: "RGB",
      components: {
        preview: true,
        opacity: false,
        hue: true,

        interaction: {
          hex: false,
          rgba: true,
          hsva: false,
          input: true,
          clear: false,
          save: false,
        },
      },
    },
  ],
];
const nanoButtons1 = [];
let nanoPickr1 = null;
for (const [theme, config] of nanoThemes) {
  const button = document.createElement("button");
  button.innerHTML = theme;
  nanoButtons1.push(button);

  button.addEventListener("click", () => {
    const el = document.createElement("p");
    pickrContainerBackground.appendChild(el);

    /* Delete previous instance */
    if (nanoPickr1) {
      nanoPickr1.destroyAndRemove();
    }

    /* Apply active class */
    for (const btn of nanoButtons) {
      btn.classList[btn === button ? "add" : "remove"]("active");
    }

    /* Create fresh instance */
    nanoPickr1 = new Pickr(
      Object.assign(
        {
          el,
          theme,
          default: "#845adf",
        },
        config
      )
    );

    /* Set events */
    nanoPickr1.on("changestop", (source, instance) => {
      let color = instance.getColor().toRGBA();
      let html = document.querySelector("html");
      html.style.setProperty(
        "--body-bg-rgb",
        `${color[0]}, ${color[1]}, ${color[2]}`
      );
      html.style.setProperty(
        "--body-bg-rgb2",
        `${color[0] + 14}, ${color[1] + 14}, ${color[2] + 14}`
      );
      html.style.setProperty(
        "--background",
        `rgba(${color[0]}, ${color[1]}, ${color[2]}, 0.86)`
      );
      document
        .querySelector("html")
        .style.setProperty(
          "--light-rgb",
          `${color[0] + 14}, ${color[1] + 14}, ${color[2] + 14}`
        );
      document
        .querySelector("html")
        .style.setProperty(
          "--form-control-bg",
          `rgb(${color[0] + 14}, ${color[1] + 14}, ${color[2] + 14})`
        );
      localStorage.removeItem("bgtheme");
      updateColors();
      html.setAttribute("data-theme-mode", "dark");
      html.setAttribute("data-menu-styles", "dark");
      html.setAttribute("data-header-styles", "dark");
      document.querySelector("#switcher-dark-theme").checked = true;
      localStorage.setItem(
        "bodyBgRGB",
        `${color[0]}, ${color[1]}, ${color[2]}`
      );
      localStorage.setItem(
        "bodyBgRGB2",
        `${color[0] + 14}, ${color[1] + 14}, ${color[2] + 14}`
      );
      localStorage.setItem(
        "bodylightRGB",
        `${color[0] + 14}, ${color[1] + 14}, ${color[2] + 14}`
      );
    });
  });
  themeContainerBackground.appendChild(button);
}
nanoButtons1[0].click();
/* for theme background */

// back to top //
const scrollToTop = document.querySelector(".scrollToTop");
const $rootElement = document.documentElement;
const $body = document.body;
window.onscroll = () => {
  const scrollTop = window.scrollY || window.pageYOffset;
  const clientHt = $rootElement.scrollHeight - $rootElement.clientHeight;
  if (window.scrollY > 100) {
    scrollToTop.style.display = "flex";
  } else {
    scrollToTop.style.display = "none";
  }
};
scrollToTop.onclick = () => {
  window.scrollTo(0, 0);
};
// back to top //

// tooltip //
const tooltipTriggerList = document.querySelectorAll(
  '[data-bs-toggle="tooltip"]'
);
const tooltipList = [...tooltipTriggerList].map(
  (tooltipTriggerEl) => new bootstrap.Tooltip(tooltipTriggerEl)
);

// popover  //
const popoverTriggerList = document.querySelectorAll(
  '[data-bs-toggle="popover"]'
);
const popoverList = [...popoverTriggerList].map(
  (popoverTriggerEl) => new bootstrap.Popover(popoverTriggerEl)
);

// card with close button //

let DIV_CARD = ".card";
let cardRemoveBtn = document.querySelectorAll('[data-bs-toggle="card-remove"]');
cardRemoveBtn.forEach((ele) => {
  ele.addEventListener("click", function (e) {
    e.preventDefault();
    let $this = this;
    let card = $this.closest(DIV_CARD);
    card.remove();
    return false;
  });
});
// card with close button //

// card with fullscreen //
let cardFullscreenBtn = document.querySelectorAll(
  '[data-bs-toggle="card-fullscreen"]'
);
cardFullscreenBtn.forEach((ele) => {
  ele.addEventListener("click", function (e) {
    let $this = this;
    let card = $this.closest(DIV_CARD);
    card.classList.toggle("card-fullscreen");
    card.classList.remove("card-collapsed");
    e.preventDefault();
    return false;
  });
});
// card with fullscreen //

/* header theme toggle */
function toggleTheme() {
  let html = document.querySelector("html");
  if (html.getAttribute("data-theme-mode") === "dark") {
    html.setAttribute("data-theme-mode", "light");
    html.setAttribute("data-header-styles", "light");
    html.setAttribute("data-menu-styles", "light");
    html.removeAttribute("data-bg-theme");
    // html.removeAttribute('style');
    document.querySelector("#switcher-light-theme").checked = true;
    document.querySelector("#switcher-menu-light").checked = true;
    document
      .querySelector("html")
      .style.removeProperty("--body-bg-rgb", localStorage.bodyBgRGB);
    document
      .querySelector("html")
      .style.removeProperty("--body-bg-rgb2", localStorage.bodyBgRGB2);
    document
      .querySelector("html")
      .style.removeProperty("--background", localStorage.bodyBgRGB);
    document
      .querySelector("html")
      .style.removeProperty("--form-control-bg", localStorage.bodyBgRGB);
    document.querySelector("html").style.removeProperty("--light-rgb", localStorage.bodyBgRGB);
    document.querySelector("html").style.removeProperty("--input-border", localStorage.bodyBgRGB);
    checkOptions();
    document.querySelector("#switcher-header-light").checked = true;
    document.querySelector("#switcher-menu-light").checked = true;
    document.querySelector("#switcher-light-theme").checked = true;
    document.querySelector("#switcher-background4").checked = false;
    document.querySelector("#switcher-background3").checked = false;
    document.querySelector("#switcher-background2").checked = false;
    document.querySelector("#switcher-background1").checked = false;
    document.querySelector("#switcher-background").checked = false;
    localStorage.removeItem("vexeldarktheme");
    localStorage.removeItem("vexelMenu");
    localStorage.removeItem("vexelHeader");
    localStorage.removeItem("bodylightRGB");
    localStorage.removeItem("bodyBgRGB");
    localStorage.removeItem("bodyBgRGB2");
    if (localStorage.getItem("vexellayout") != "horizontal") {
      html.setAttribute("data-menu-styles", "dark");
    }
    html.setAttribute("data-header-styles", "light");
  } else {
    html.setAttribute("data-theme-mode", "dark");
    html.setAttribute("data-header-styles", "dark");
    html.setAttribute("data-menu-styles", "dark");
    document.querySelector("#switcher-dark-theme").checked = true;
    document.querySelector("#switcher-menu-dark").checked = true;
    document.querySelector("#switcher-header-dark").checked = true;
    checkOptions();
    document.querySelector("#switcher-menu-dark").checked = true;
    document.querySelector("#switcher-header-dark").checked = true;
    document.querySelector("#switcher-dark-theme").checked = true;
    document.querySelector("#switcher-background4").checked = false;
    document.querySelector("#switcher-background3").checked = false;
    document.querySelector("#switcher-background2").checked = false;
    document.querySelector("#switcher-background1").checked = false;
    document.querySelector("#switcher-background").checked = false;
    localStorage.setItem("vexeldarktheme", "true");
    localStorage.setItem("vexelMenu", "dark");
    localStorage.setItem("vexelHeader", "dark");
    localStorage.removeItem("bodylightRGB");
    localStorage.removeItem("bodyBgRGB");
  }
}
let layoutSetting = document.querySelector(".layout-setting");
layoutSetting.addEventListener("click", toggleTheme);
/* header theme toggle */

// REPLY
function replay() {
  "use strict";

  let replayButtom = document.querySelectorAll(".reply a");
  // Creating Div
  let Div = document.createElement("div");
  Div.setAttribute("class", "comment mt-5 d-grid");
  // creating textarea
  let textArea = document.createElement("textarea");
  textArea.setAttribute("class", "form-control");
  textArea.setAttribute("rows", "5");
  textArea.innerText = "Your Comment";
  // creating Cancel buttons
  let cancelButton = document.createElement("button");
  cancelButton.setAttribute("class", "btn btn-danger");
  cancelButton.innerText = "Cancel";

  let buttonDiv = document.createElement("div");
  buttonDiv.setAttribute("class", "btn-list ms-auto mt-2");

  // Creating submit button
  let submitButton = document.createElement("button");
  submitButton.setAttribute("class", "btn btn-success");
  submitButton.innerText = "Submit";
}
replay();
// FOOTER
if (!document.querySelector(".login-img")) {
  document.getElementById("year").innerHTML = new Date().getFullYear();
}

/* Choices JS */
document.addEventListener("DOMContentLoaded", function () {
  var genericExamples = document.querySelectorAll("[data-trigger]");
  for (let i = 0; i < genericExamples.length; ++i) {
    var element = genericExamples[i];
    new Choices(element, {
      allowHTML: true,
      placeholderValue: "This is a placeholder set in the config",
      searchPlaceholderValue: "Search",
    });
  }
});
/* Choices JS */

/* full screen */
var elem = document.documentElement;
function openFullscreen() {
  let open = document.querySelector(".full-screen-open");
  let close = document.querySelector(".full-screen-close");
  if (!document.fullscreenElement) {
    if (elem.requestFullscreen) {
      elem.requestFullscreen();
    } else if (elem.webkitRequestFullscreen) {
      /* Safari */
      elem.webkitRequestFullscreen();
    } else if (elem.msRequestFullscreen) {
      /* IE11 */
      elem.msRequestFullscreen();
    }
    close.classList.add("d-block");
    close.classList.remove("d-none");
    open.classList.add("d-none");
  } else {
    if (document.exitFullscreen) {
      document.exitFullscreen();
    } else if (document.webkitExitFullscreen) {
      /* Safari */
      document.webkitExitFullscreen();
    } else if (document.msExitFullscreen) {
      /* IE11 */
      document.msExitFullscreen();
    }
    close.classList.remove("d-block");
    open.classList.remove("d-none");
    close.classList.add("d-none");
    open.classList.add("d-block");
  }
}

/* toggle switches */
let customSwitch = document.querySelectorAll(".toggle");
customSwitch.forEach((e) =>
  e.addEventListener("click", () => {
    e.classList.toggle("on");
  })
);
/* toggle switches */

/* for cart dropdown */
const headerbtn = document.querySelectorAll(".dropdown-item-close");
headerbtn.forEach((button) => {
  button.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    button.parentNode.parentNode.parentNode.parentNode.parentNode.remove();
    document.getElementById("cart-data").innerText = `${
      document.querySelectorAll(".dropdown-item-close").length
    } Items`;
    document.getElementById("cart-icon-badge").innerText = `${
      document.querySelectorAll(".dropdown-item-close").length
    }`;
    console.log(
      document.getElementById("header-cart-items-scroll").children.length
    );
    if (document.querySelectorAll(".dropdown-item-close").length == 0) {
      let elementHide = document.querySelector(".empty-header-item");
      let elementShow = document.querySelector(".empty-item");
      elementHide.classList.add("d-none");
      elementShow.classList.remove("d-none");
    }
  });
});
/* for cart dropdown */

/* for notifications dropdown */
const headerbtn1 = document.querySelectorAll(".dropdown-item-close1");
headerbtn1.forEach((button) => {
  button.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    button.parentNode.parentNode.parentNode.parentNode.remove();
    document.getElementById("notifiation-data").innerText = `${
      document.querySelectorAll(".dropdown-item-close1").length
    } Unread`;
    document.getElementById("notification-icon-badge").innerText = `${
      document.querySelectorAll(".dropdown-item-close1").length
    }`;
    if (document.querySelectorAll(".dropdown-item-close1").length == 0) {
      let elementHide1 = document.querySelector(".empty-header-item1");
      let elementShow1 = document.querySelector(".empty-item1");
      elementHide1.classList.add("d-none");
      elementShow1.classList.remove("d-none");
    }
  });
});
/* for notifications dropdown */

/*  */
let typehead = document.querySelector("#typehead");
typehead.addEventListener("click", showSearchResult);
document.body.addEventListener("click", removeSearchResult);

function showSearchResult(event) {
  event.preventDefault();
  event.stopPropagation();
  let headerSearch = document.querySelector("#headersearch");
  headerSearch.classList.add("searchdrop");
}
function removeSearchResult(event) {
  let headerSearch = document.querySelector("#headersearch");
  if (
    event.target.classList.contains("header-search") ||
    event.target.closest(".header-search")
  ) {
    return;
  }
  headerSearch.classList.remove("searchdrop");
}
